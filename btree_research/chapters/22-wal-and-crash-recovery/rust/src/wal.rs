//! wal.rs: a write-ahead log with full page images (physical redo).
//!
//! The `Wal` sits between the pager and two files, and looks like a storage
//! to the pager (chapter 12's trait, see adapter.rs):
//!
//! ```text
//! DiskBTree -> BufferPool -> Pager -> Wal -+-> log file   (appended, synced at commit)
//!                                          +-> main file  (written only by checkpoint)
//!
//! write(page)   keep the image in `pending` (memory). Nothing reaches a file.
//! sync()        COMMIT: append one record per pending page and a commit
//!               record to the log, sync the log. The images move to `index`.
//! read(page)    newest image wins: pending, then index, then the main file
//!               (whose page checksum is verified).
//! checkpoint()  write every image of `index` to the main file, sync it,
//!               then start a new, empty generation of the log.
//! recover()     on open: scan the log, replay committed operations into
//!               the main file, start a new generation.
//! ```
//!
//! The write-ahead rule: a page reaches the main file only after the log
//! record holding its image is durable. `checkpoint` and `recover` are the
//! only code that writes the main file. `checkpoint` writes images whose
//! commit synced the log. `recover` writes images it read back from the log,
//! and readable is not durable (an earlier sync may have failed with the
//! power on), so it syncs the log itself before its first main-file write.
//!
//! The buffer pool may evict a dirty page in the middle of an operation. Its
//! write-back arrives here as `write` and lands in `pending`, so eviction is
//! routed through the log and can never put an uncommitted page into the main
//! file. The pool needs no change and can stay as small as 2 frames.
//!
//! Log file layout (all integers little-endian)
//! ============================================
//!
//! ```text
//! log page 0          header, alone on its page
//!    0  [8]  magic "WAL22\0\0\0"
//!    8  u32  format version (1)
//!   12  u32  page size (4096)
//!   16  u64  generation: +1 at every reset; the old records stay in the
//!            file but no longer chain from the header
//!   24  u64  LSN of the first record of this generation
//!   32  u32  CRC-32 of bytes 0..32
//! byte 4096 onwards   records, back to back, crossing page boundaries
//!    0  u64  LSN (log sequence number): 1, 2, 3, ... never reused
//!    8  u32  kind: 1 = page image, 2 = commit
//!   12  u32  page image: the page id; commit: number of page records
//!   16  u32  payload length: 4096 for a page image, 0 for a commit
//!   20  u32  CRC-32 of (previous record's CRC ++ bytes 0..20 ++ payload)
//!   24  ...  payload
//! ```
//!
//! The checksum chain. Each CRC covers the CRC before it; the first one
//! covers the header's CRC. A record is valid only if every record before it
//! is valid. So the scan stops at the first torn record, and also at a record
//! left over from an earlier generation: it has a good CRC of its own, but
//! not one that chains from today's header.
//!
//! Why the header page is safe to overwrite in place: all of it lies in the
//! first 512-byte sector, which the disk writes atomically (chapter 21).
//! Why rewriting the last, partly filled log page is safe: the bytes of the
//! earlier records on it are rewritten with identical contents, so a sector
//! that is torn there is the same before and after.
//!
//! Memory. Zig assembles the records of a commit with a FixedBufferAllocator
//! over one slab and reads the log into an arena during recovery. Here the
//! slab is a `Vec<u8>` whose capacity is reserved once and never exceeded
//! (`record_limit`), and recovery's images are `Box`es owned by locals that
//! are dropped together when `recover` returns.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use crate::adapter::whole_page;
use crate::base_checksum::{self as checksum, Check};
pub use crate::base_page_storage::{PAGE_SIZE, Page};
use crate::base_page_storage::{Storage as PageStorage, StorageError};
use crate::base_storage::{Error as ByteError, Storage as ByteStorage};
use crate::crc32::{crc32, crc32_update};

pub type PageId = u32;

pub const LOG_MAGIC: &[u8; 8] = b"WAL22\0\0\0";
pub const LOG_VERSION: u32 = 1;
/// Byte offset of the first record: the header has log page 0 to itself.
pub const LOG_START: u64 = PAGE_SIZE as u64;
pub const RECORD_HEADER_LEN: usize = 24;
pub const KIND_PAGE: u32 = 1;
pub const KIND_COMMIT: u32 = 2;

/// Sorted map from page id to an owned page image. Zig writes a small sorted
/// array by hand; `BTreeMap` is the same thing from the standard library, and
/// iterating it also visits pages in page-id order.
pub type PageTable = BTreeMap<PageId, Box<Page>>;

/// Number of pages needed to hold the highest page id (0 if empty).
fn table_page_count(table: &PageTable) -> u64 {
    table.keys().next_back().map_or(0, |&id| u64::from(id) + 1)
}

/// What `recover` found in the log.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Recovery {
    /// Generation of the log that was scanned (0 = there was no log).
    pub generation: u64,
    /// Records whose checksum chain was intact.
    pub valid_records: u32,
    /// Operations with a commit record: these were replayed.
    pub committed_ops: u32,
    /// Distinct pages written to the main file by the replay.
    pub pages_replayed: u32,
    /// Valid page records after the last commit record: an operation that
    /// was still being logged when the power failed. Ignored.
    pub uncommitted_records: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub commits: u64,
    pub page_records: u64,
    /// Bytes of records appended to the log, over all generations.
    pub log_bytes: u64,
    /// The longest the record area of the log ever was, in bytes.
    pub max_log_bytes: u64,
    /// The most page images one commit carried.
    pub largest_commit: u64,
    pub log_page_writes: u64,
    pub log_syncs: u64,
    pub checkpoints: u64,
    pub main_page_writes: u64,
    pub main_syncs: u64,
    /// Pages read from the main file whose checksum did not verify.
    pub checksum_failures: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// Upper bound on the pages one commit may log; sizes `record_buffer`.
    pub max_commit_pages: u32,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_commit_pages: 32,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalError {
    /// One of the two files failed (`PowerLoss`, ...).
    Storage(StorageError),
    /// The log header is damaged in a way a power cut cannot explain.
    LogCorrupt,
    /// One commit dirtied more pages than `max_commit_pages`.
    CommitTooLarge,
    /// An earlier commit or checkpoint failed; reopen to recover.
    WalBroken,
}

impl From<StorageError> for WalError {
    fn from(e: StorageError) -> Self {
        WalError::Storage(e)
    }
}

pub struct Wal {
    main: Box<dyn PageStorage>,
    log: Box<dyn PageStorage>,
    /// Images the pager wrote since the last commit. Volatile, uncommitted.
    pending: PageTable,
    /// Committed images that are in the log but not yet in the main file.
    /// (SQLite and Turso keep frame numbers here and re-read the log; this
    /// chapter keeps the images themselves.)
    index: PageTable,
    pub generation: u64,
    next_lsn: u64,
    /// CRC of the last valid record (or of the header): the chain's end.
    chain: u32,
    /// Byte offset in the log file where the next record goes.
    tail: u64,
    /// The contents of the log page that contains `tail`.
    tail_page: Box<Page>,
    /// The records of the commit being assembled; never grows past the limit.
    record_buffer: Vec<u8>,
    record_limit: usize,
    pub commits_in_log: u32,
    /// Set while the files and this struct may disagree: before `recover`,
    /// and after a commit or checkpoint failed half-way. Only a new `Wal`
    /// that runs `recover` can be trusted then.
    broken: bool,
    /// The most recent error that the storage trait had to flatten.
    pub last_error: Option<WalError>,
    pub stats: Stats,
}

impl Wal {
    /// Allocate the record buffer. The log is not read: call `recover` next.
    pub fn new(main: Box<dyn PageStorage>, log: Box<dyn PageStorage>, options: Options) -> Self {
        let record_limit =
            options.max_commit_pages as usize * (RECORD_HEADER_LEN + PAGE_SIZE) + RECORD_HEADER_LEN;
        Self {
            main,
            log,
            pending: PageTable::new(),
            index: PageTable::new(),
            generation: 0,
            next_lsn: 1,
            chain: 0,
            tail: LOG_START,
            tail_page: Box::new([0; PAGE_SIZE]),
            record_buffer: Vec::with_capacity(record_limit),
            record_limit,
            commits_in_log: 0,
            broken: true,
            last_error: None,
            stats: Stats::default(),
        }
    }

    // ---- commit ---------------------------------------------------------------

    /// Make every pending page image durable as ONE operation: page records,
    /// then a commit record, then one sync of the log. When this returns the
    /// operation survives any crash; if the power fails before the sync
    /// completes, recovery sees no commit record and ignores all of it.
    pub fn commit(&mut self) -> Result<(), WalError> {
        if self.broken {
            return Err(WalError::WalBroken);
        }
        if self.pending.is_empty() {
            return Ok(()); // nothing changed: nothing to log
        }

        // Assemble the records back to back in the fixed buffer. Its used
        // prefix IS the byte run to append; running out of it is the size
        // limit.
        self.record_buffer.clear();
        let mut chain = self.chain;
        let mut lsn = self.next_lsn;
        for (&id, image) in &mut self.pending {
            // Seal first: the image in the log carries the page checksum, so
            // checkpoint and recovery can copy it to the main file verbatim.
            checksum::seal(image, u64::from(id));
            chain = append_record(
                &mut self.record_buffer,
                self.record_limit,
                lsn,
                KIND_PAGE,
                id,
                &image[..],
                chain,
            )?;
            lsn += 1;
        }
        let pages = self.pending.len();
        chain = append_record(
            &mut self.record_buffer,
            self.record_limit,
            lsn,
            KIND_COMMIT,
            pages as u32,
            &[],
            chain,
        )?;
        lsn += 1;

        // From here on a failure leaves the log in a state only recovery
        // can interpret.
        self.broken = true;
        self.append_to_log()?;
        self.log.sync()?;
        self.stats.log_syncs += 1;
        // ---- the commit point: the operation is durable ----

        // Ownership of each image moves; an older image of the page is dropped.
        self.index.append(&mut self.pending);
        self.stats.page_records += pages as u64;
        self.stats.largest_commit = self.stats.largest_commit.max(pages as u64);
        self.chain = chain;
        self.next_lsn = lsn;
        self.commits_in_log += 1;
        self.stats.commits += 1;
        self.stats.log_bytes += self.record_buffer.len() as u64;
        self.stats.max_log_bytes = self.stats.max_log_bytes.max(self.tail - LOG_START);
        self.broken = false;
        Ok(())
    }

    /// Write `record_buffer` at `tail`. The log file is page-addressed, so
    /// the first write usually rewrites the partly filled last page (see the
    /// top).
    fn append_to_log(&mut self) -> Result<(), WalError> {
        let mut rest = &self.record_buffer[..];
        while !rest.is_empty() {
            let offset = (self.tail % PAGE_SIZE as u64) as usize;
            if offset == 0 {
                self.tail_page.fill(0);
            }
            let n = rest.len().min(PAGE_SIZE - offset);
            self.tail_page[offset..offset + n].copy_from_slice(&rest[..n]);
            self.log
                .write_page(self.tail / PAGE_SIZE as u64, &self.tail_page)?;
            self.stats.log_page_writes += 1;
            self.tail += n as u64;
            rest = &rest[n..];
        }
        Ok(())
    }

    // ---- checkpoint -----------------------------------------------------------

    /// Copy every committed image to the main file, sync it, then empty the
    /// log. A crash anywhere in here is harmless: until the new log header
    /// is durable the old log is still complete, and recovery replays it
    /// over whatever the interrupted checkpoint left (redo is idempotent:
    /// writing the same image twice gives the same page).
    pub fn checkpoint(&mut self) -> Result<(), WalError> {
        if self.broken {
            return Err(WalError::WalBroken);
        }
        self.broken = true;
        let index = std::mem::take(&mut self.index);
        self.write_to_main(&index)?;
        self.reset_log()?;
        self.stats.checkpoints += 1;
        self.broken = false;
        Ok(())
    }

    fn write_to_main(&mut self, table: &PageTable) -> Result<(), WalError> {
        if table.is_empty() {
            return Ok(());
        }
        for (&id, image) in table {
            self.main.write_page(u64::from(id), image)?;
            self.stats.main_page_writes += 1;
        }
        self.main.sync()?;
        self.stats.main_syncs += 1;
        Ok(())
    }

    /// Start a new generation: one header write, one sync. The old records
    /// are not erased; they stop being reachable because their checksums
    /// chain from the old header.
    fn reset_log(&mut self) -> Result<(), WalError> {
        let mut header = [0u8; PAGE_SIZE];
        let header_crc = encode_header(&mut header, self.generation + 1, self.next_lsn);
        self.log.write_page(0, &header)?;
        self.stats.log_page_writes += 1;
        self.log.sync()?;
        self.stats.log_syncs += 1;
        self.generation += 1;
        self.chain = header_crc;
        self.tail = LOG_START;
        self.commits_in_log = 0;
        Ok(())
    }

    // ---- recovery -------------------------------------------------------------

    /// Bring the main file to the state after the last committed operation.
    ///
    ///   1. scan the log from the start; stop at the first record whose
    ///      checksum chain breaks (torn, never written, or an old generation)
    ///   2. page records are collected per operation; a commit record
    ///      promotes them, a missing one means they are dropped
    ///   3. sync the log, write the newest committed image of each page to
    ///      the main file, sync, start a new log generation (a checkpoint)
    ///
    /// Running it twice, or crashing inside it and running it again, gives
    /// the same main file: step 3 only copies images.
    pub fn recover(&mut self) -> Result<Recovery, WalError> {
        // Every image read from the log is owned by these locals and dropped
        // with them when recovery is over (Zig: one arena, freed at once).
        let mut committed = PageTable::new();
        let mut open_op: Vec<(PageId, Box<Page>)> = Vec::new(); // records since the last commit
        let mut scanner = LogScanner::new(self.log.as_mut())?;
        let mut report = Recovery {
            generation: scanner.generation,
            ..Recovery::default()
        };
        let mut image: Box<Page> = Box::new([0; PAGE_SIZE]);
        while let Some(rec) = scanner.next(&mut image)? {
            report.valid_records += 1;
            if rec.kind == KIND_PAGE {
                // The image is in use; the next record gets a new one.
                open_op.push((
                    rec.arg,
                    std::mem::replace(&mut image, Box::new([0; PAGE_SIZE])),
                ));
                continue;
            }
            // A commit record says how many page records it closes; with an
            // intact chain the count cannot be wrong unless the writer was.
            if rec.arg as usize != open_op.len() {
                return Err(WalError::LogCorrupt);
            }
            // The newest image of a page wins; an older one is dropped.
            committed.extend(open_op.drain(..));
            report.committed_ops += 1;
        }
        report.uncommitted_records = open_op.len() as u32;
        report.pages_replayed = committed.len() as u32;

        // Redo, then checkpoint. `next_lsn` moves past every record that was
        // valid, committed or not, so no LSN is ever handed out twice.
        self.generation = scanner.generation;
        self.next_lsn = scanner.lsn;
        if !committed.is_empty() {
            // The write-ahead rule. The records were READ from the log; that
            // does not make them durable. If the sync of their commit failed
            // while the power stayed on, they sit in the operating system's
            // cache, and a power cut during the writes below could keep the
            // main-file pages and lose the records they came from.
            self.log.sync()?;
            self.stats.log_syncs += 1;
        }
        self.write_to_main(&committed)?;
        self.reset_log()?;
        self.broken = false;
        Ok(report)
    }

    // ---- the storage interface the pager sees ------------------------------------

    /// Pages in the database as the tree sees it: the main file, extended
    /// by any newer page that so far exists only in the log or in memory.
    pub fn page_count(&self) -> u64 {
        self.main
            .size()
            .max(table_page_count(&self.index))
            .max(table_page_count(&self.pending))
    }

    fn fail(&mut self, err: WalError) -> ByteError {
        self.last_error = Some(err);
        ByteError::StorageFailure
    }

    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), ByteError> {
        if self.broken {
            return Err(self.fail(WalError::WalBroken));
        }
        let page_no = whole_page(offset, buffer.len()).ok_or(ByteError::StorageFailure)?;
        if page_no >= self.page_count() {
            return Err(ByteError::ShortRead);
        }
        let out: &mut Page = buffer.try_into().expect("a whole page");
        let id = page_no as PageId;
        if let Some(image) = self.pending.get(&id).or_else(|| self.index.get(&id)) {
            *out = **image;
        } else {
            match checksum::read_checked(self.main.as_mut(), page_no, out) {
                Ok(Check::Ok) => {}
                // Every page of the main file was written by a checkpoint,
                // sealed. Anything else is damage the log can no longer repair.
                Ok(Check::Blank | Check::Corrupt) => {
                    self.stats.checksum_failures += 1;
                    return Err(ByteError::StorageFailure);
                }
                Err(err) => return Err(self.fail(err.into())),
            }
        }
        // The tree was promised a zero tail (chapter 12); the checksum that
        // lives there on disk is this layer's business only.
        out[checksum::PAYLOAD_SIZE..].fill(0);
        Ok(())
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), ByteError> {
        if self.broken {
            return Err(self.fail(WalError::WalBroken));
        }
        let page_no = whole_page(offset, bytes.len()).ok_or(ByteError::StorageFailure)?;
        if page_no >= u64::from(PageId::MAX) {
            return Err(ByteError::StorageFailure);
        }
        let page: &Page = bytes.try_into().expect("a whole page");
        self.pending.insert(page_no as PageId, Box::new(*page));
        Ok(())
    }
}

/// The handle the pager owns. The `Db` keeps a second one to the same `Wal`
/// (for checkpoints and statistics), so the log is shared: `Rc<RefCell<..>>`.
/// In Zig the pager simply holds a pointer to the `Wal` inside the `Db`.
pub struct WalStorage(pub Rc<RefCell<Wal>>);

impl ByteStorage for WalStorage {
    fn read(&mut self, offset: u64, buffer: &mut [u8]) -> Result<(), ByteError> {
        self.0.borrow_mut().read(offset, buffer)
    }

    fn write(&mut self, offset: u64, bytes: &[u8]) -> Result<(), ByteError> {
        self.0.borrow_mut().write(offset, bytes)
    }

    fn size(&mut self) -> Result<u64, ByteError> {
        Ok(self.0.borrow().page_count() * PAGE_SIZE as u64)
    }

    fn sync(&mut self) -> Result<(), ByteError> {
        let mut wal = self.0.borrow_mut();
        wal.commit().map_err(|err| wal.fail(err))
    }
}

// ---- reading the log -----------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Record {
    pub lsn: u64,
    pub kind: u32,
    pub arg: u32,
    pub crc: u32,
    pub offset: u64,
}

/// Walks the valid prefix of the log: `next` returns one record after the
/// other and None as soon as the checksum chain ends. Used by recovery, and
/// by anything that wants to look at a log (the demo prints one).
pub struct LogScanner<'a> {
    log: &'a mut dyn PageStorage,
    /// 0 = the file has no header: there is no log.
    pub generation: u64,
    /// The LSN the next record must carry.
    pub lsn: u64,
    /// The CRC the next record must chain from.
    chain: u32,
    /// Byte offset of the next record.
    pub pos: u64,
    cached: Option<u64>,
    page: Box<Page>,
}

impl<'a> LogScanner<'a> {
    pub fn new(log: &'a mut dyn PageStorage) -> Result<Self, WalError> {
        let mut scanner = Self {
            log,
            generation: 0,
            lsn: 1,
            chain: 0,
            pos: LOG_START,
            cached: None,
            page: Box::new([0; PAGE_SIZE]),
        };
        let mut header = [0u8; PAGE_SIZE];
        if scanner.read(0, &mut header)? {
            if let Some(h) = decode_header(&header) {
                scanner.generation = h.generation;
                scanner.lsn = h.first_lsn;
                scanner.chain = h.crc;
            } else if header.iter().any(|&b| b != 0) {
                return Err(WalError::LogCorrupt);
            }
        }
        Ok(scanner)
    }

    /// The next valid record, or None at the end of the chain. For a page
    /// record its image is copied to `image`.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self, image: &mut Page) -> Result<Option<Record>, WalError> {
        if self.generation == 0 {
            return Ok(None);
        }
        let mut head = [0u8; RECORD_HEADER_LEN];
        if !self.read(self.pos, &mut head)? {
            return Ok(None); // end of the file
        }
        let kind = le_u32(&head[8..12]);
        let payload_len = le_u32(&head[16..20]) as usize;
        // Cheap plausibility checks before trusting the length field. A
        // record with the wrong LSN is stale even if its bytes are intact.
        if u64::from_le_bytes(head[0..8].try_into().expect("8 bytes")) != self.lsn {
            return Ok(None);
        }
        let is_page = kind == KIND_PAGE && payload_len == PAGE_SIZE;
        if !is_page && !(kind == KIND_COMMIT && payload_len == 0) {
            return Ok(None);
        }
        if is_page && !self.read(self.pos + RECORD_HEADER_LEN as u64, image)? {
            return Ok(None);
        }
        let payload: &[u8] = if is_page { &image[..] } else { &[] };
        let sum = record_crc(self.chain, &head[..20], payload);
        if sum != le_u32(&head[20..24]) {
            return Ok(None); // the chain breaks here
        }
        let rec = Record {
            lsn: self.lsn,
            kind,
            arg: le_u32(&head[12..16]),
            crc: sum,
            offset: self.pos,
        };
        self.chain = sum;
        self.lsn += 1;
        self.pos += (RECORD_HEADER_LEN + payload_len) as u64;
        Ok(Some(rec))
    }

    /// Copy a byte range of the page-addressed log file, through a one-page
    /// cache. false = the range reaches past the end of the file.
    fn read(&mut self, pos: u64, out: &mut [u8]) -> Result<bool, StorageError> {
        let mut done = 0;
        while done < out.len() {
            let at = pos + done as u64;
            let page_no = at / PAGE_SIZE as u64;
            if self.cached != Some(page_no) {
                self.cached = None;
                match self.log.read_page(page_no, &mut self.page) {
                    Ok(()) => {}
                    Err(StorageError::OutOfBounds) => return Ok(false),
                    Err(err) => return Err(err),
                }
                self.cached = Some(page_no);
            }
            let offset = (at % PAGE_SIZE as u64) as usize;
            let n = (out.len() - done).min(PAGE_SIZE - offset);
            out[done..done + n].copy_from_slice(&self.page[offset..offset + n]);
            done += n;
        }
        Ok(true)
    }
}

// ---- encoding ------------------------------------------------------------------

fn le_u32(bytes: &[u8]) -> u32 {
    u32::from_le_bytes(bytes.try_into().expect("4 bytes"))
}

/// Append one record (header, then payload) to `buffer` and return its CRC,
/// the next link of the chain. `limit` is the buffer's fixed size.
pub fn append_record(
    buffer: &mut Vec<u8>,
    limit: usize,
    lsn: u64,
    kind: u32,
    arg: u32,
    payload: &[u8],
    prev_crc: u32,
) -> Result<u32, WalError> {
    if buffer.len() + RECORD_HEADER_LEN + payload.len() > limit {
        return Err(WalError::CommitTooLarge);
    }
    let start = buffer.len();
    buffer.extend_from_slice(&lsn.to_le_bytes());
    buffer.extend_from_slice(&kind.to_le_bytes());
    buffer.extend_from_slice(&arg.to_le_bytes());
    buffer.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    let sum = record_crc(prev_crc, &buffer[start..start + 20], payload);
    buffer.extend_from_slice(&sum.to_le_bytes());
    buffer.extend_from_slice(payload);
    Ok(sum)
}

/// One link of the checksum chain: CRC-32 over the previous record's CRC
/// (4 bytes, little-endian), the first 20 header bytes, and the payload.
pub fn record_crc(prev_crc: u32, head: &[u8], payload: &[u8]) -> u32 {
    crc32_update(crc32_update(crc32(&prev_crc.to_le_bytes()), head), payload)
}

pub fn encode_header(page: &mut Page, generation: u64, first_lsn: u64) -> u32 {
    page.fill(0);
    page[0..8].copy_from_slice(LOG_MAGIC);
    page[8..12].copy_from_slice(&LOG_VERSION.to_le_bytes());
    page[12..16].copy_from_slice(&(PAGE_SIZE as u32).to_le_bytes());
    page[16..24].copy_from_slice(&generation.to_le_bytes());
    page[24..32].copy_from_slice(&first_lsn.to_le_bytes());
    let sum = crc32(&page[0..32]);
    page[32..36].copy_from_slice(&sum.to_le_bytes());
    sum
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub generation: u64,
    pub first_lsn: u64,
    pub crc: u32,
}

pub fn decode_header(page: &Page) -> Option<Header> {
    if &page[0..8] != LOG_MAGIC
        || le_u32(&page[8..12]) != LOG_VERSION
        || le_u32(&page[12..16]) != PAGE_SIZE as u32
    {
        return None;
    }
    let sum = crc32(&page[0..32]);
    if le_u32(&page[32..36]) != sum {
        return None;
    }
    Some(Header {
        generation: u64::from_le_bytes(page[16..24].try_into().expect("8 bytes")),
        first_lsn: u64::from_le_bytes(page[24..32].try_into().expect("8 bytes")),
        crc: sum,
    })
}
