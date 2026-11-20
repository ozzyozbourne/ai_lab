//! machine.rs: two files on one simulated computer, with one power switch.
//!
//! A database with a write-ahead log has two files: the main file (the tree's
//! pages) and the log. Chapter 21's `SimDisk` simulates ONE file that can lose
//! power. A `Machine` owns two of them and gives them a common power supply:
//!
//! ```text
//! power_off_after_writes(n)  n more page writes succeed, counted over BOTH
//!                            files; after that every call on either file
//!                            fails with PowerLoss
//! crash(mode)                each file decides the fate of its unsynced
//!                            writes (drop, keep, tear, random), then the
//!                            power is back on
//! ```
//!
//! `main_storage()` and `log_storage()` hand out chapter 21's `Storage`
//! trait objects, so everything written against it (the checksummed pages,
//! the log, the adapter of adapter.rs) runs on the machine unchanged.
//!
//! The machine can also record a trace of every write and sync. The demo
//! prints it, and the visualization replays it.
//!
//! Zig hands out two interface values that point at one `Machine` on the
//! stack. Two owners of one mutable thing need `Rc<RefCell<..>>` here.

use std::cell::RefCell;
use std::rc::Rc;

use crate::base_page_storage::{Page, Storage, StorageError};
pub use crate::base_sim_disk::CrashMode;
use crate::base_sim_disk::SimDisk;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileId {
    Main,
    Log,
}

impl FileId {
    pub fn name(self) -> &'static str {
        match self {
            FileId::Main => "main",
            FileId::Log => "log",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    Write,
    Sync,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub file: FileId,
    pub kind: EventKind,
    /// The page written; 0 for a sync.
    pub page_no: u64,
}

pub struct Machine {
    pub main: SimDisk,
    pub log: SimDisk,
    /// None = power stays on. Some(n) = that many more writes succeed.
    writes_left: Option<u64>,
    /// Page writes accepted so far, on both files together. This is the
    /// clock of the crash loop: "crash after write number N".
    pub writes: u64,
    pub tracing: bool,
    pub trace: Vec<Event>,
}

/// The machine as shared by its two storage ports and by the test driving it.
pub type SharedMachine = Rc<RefCell<Machine>>;

impl Machine {
    /// The two disks draw their crash randomness from different streams
    /// derived from one seed, so a run is reproduced by that seed.
    pub fn new(seed: u64) -> SharedMachine {
        Rc::new(RefCell::new(Machine {
            main: SimDisk::new(seed),
            log: SimDisk::new(seed ^ 0x9E37_79B9_7F4A_7C15),
            writes_left: None,
            writes: 0,
            tracing: false,
            trace: Vec::new(),
        }))
    }

    pub fn disk(&mut self, file: FileId) -> &mut SimDisk {
        match file {
            FileId::Main => &mut self.main,
            FileId::Log => &mut self.log,
        }
    }

    pub fn power_off_after_writes(&mut self, n: u64) {
        self.writes_left = Some(n);
        if n == 0 {
            self.cut_power();
        }
    }

    pub fn is_powered_off(&self) -> bool {
        self.main.is_powered_off()
    }

    /// Power cut and reboot of both files.
    pub fn crash(&mut self, mode: CrashMode) {
        self.main.crash(mode);
        self.log.crash(mode);
        self.writes_left = None;
    }

    fn cut_power(&mut self) {
        self.main.power_off_after_writes(0);
        self.log.power_off_after_writes(0);
    }
}

/// One of the machine's two files, as a chapter 21 `Storage`.
pub struct Port {
    machine: SharedMachine,
    file: FileId,
}

pub fn main_storage(machine: &SharedMachine) -> Box<dyn Storage> {
    Box::new(Port {
        machine: Rc::clone(machine),
        file: FileId::Main,
    })
}

pub fn log_storage(machine: &SharedMachine) -> Box<dyn Storage> {
    Box::new(Port {
        machine: Rc::clone(machine),
        file: FileId::Log,
    })
}

impl Storage for Port {
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError> {
        self.machine
            .borrow_mut()
            .disk(self.file)
            .read_page(page_no, out)
    }

    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
        let mut m = self.machine.borrow_mut();
        m.disk(self.file).write_page(page_no, page)?;
        if m.tracing {
            m.trace.push(Event {
                file: self.file,
                kind: EventKind::Write,
                page_no,
            });
        }
        m.writes += 1;
        if let Some(left) = &mut m.writes_left {
            *left -= 1;
            // The write that used up the budget still succeeded; the power
            // fails right after it, for both files.
            if *left == 0 {
                m.cut_power();
            }
        }
        Ok(())
    }

    fn sync(&mut self) -> Result<(), StorageError> {
        let mut m = self.machine.borrow_mut();
        m.disk(self.file).sync()?;
        if m.tracing {
            m.trace.push(Event {
                file: self.file,
                kind: EventKind::Sync,
                page_no: 0,
            });
        }
        Ok(())
    }

    fn size(&self) -> u64 {
        let m = self.machine.borrow();
        match self.file {
            FileId::Main => m.main.size(),
            FileId::Log => m.log.size(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::base_page_storage::PAGE_SIZE;

    #[test]
    fn one_power_switch_for_two_files() {
        let m = Machine::new(1);
        let mut main = main_storage(&m);
        let mut log = log_storage(&m);
        let page = [b'x'; PAGE_SIZE];

        m.borrow_mut().power_off_after_writes(2);
        log.write_page(0, &page).unwrap();
        log.sync().unwrap();
        main.write_page(0, &page).unwrap(); // the second write still succeeds
        assert!(m.borrow().is_powered_off());
        assert_eq!(main.sync(), Err(StorageError::PowerLoss));
        assert_eq!(log.write_page(1, &page), Err(StorageError::PowerLoss));
        let mut out = [0u8; PAGE_SIZE];
        assert_eq!(log.read_page(0, &mut out), Err(StorageError::PowerLoss));
        assert_eq!(m.borrow().writes, 2);

        m.borrow_mut().crash(CrashMode::Drop);
        log.read_page(0, &mut out).unwrap(); // synced before the power cut: still there
        assert_eq!(out, page);
        assert_eq!(main.size(), 0); // never synced: gone
    }

    #[test]
    fn the_trace_lists_writes_and_syncs_in_order() {
        let m = Machine::new(1);
        m.borrow_mut().tracing = true;
        let page = [0u8; PAGE_SIZE];
        let mut log = log_storage(&m);
        log.write_page(3, &page).unwrap();
        log.sync().unwrap();
        main_storage(&m).write_page(1, &page).unwrap();
        let m = m.borrow();
        assert_eq!(m.trace.len(), 3);
        assert_eq!(
            m.trace[0],
            Event {
                file: FileId::Log,
                kind: EventKind::Write,
                page_no: 3
            }
        );
        assert_eq!(
            m.trace[1],
            Event {
                file: FileId::Log,
                kind: EventKind::Sync,
                page_no: 0
            }
        );
        assert_eq!(
            m.trace[2],
            Event {
                file: FileId::Main,
                kind: EventKind::Write,
                page_no: 1
            }
        );
    }
}
