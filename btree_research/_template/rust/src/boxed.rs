//! Owned-pointer tree with `Box`: fine for purely top-down structures where a
//! node is owned by exactly one parent (no parent/sibling links).

#[derive(Debug)]
pub enum Node<K, V> {
    Leaf {
        keys: Vec<K>,
        values: Vec<V>,
    },
    Internal {
        keys: Vec<K>,
        children: Vec<Box<Node<K, V>>>,
    },
}

impl<K: Ord, V> Node<K, V> {
    pub fn get(&self, key: &K) -> Option<&V> {
        let mut node = self;
        loop {
            match node {
                Node::Leaf { keys, values } => {
                    return keys.binary_search(key).ok().map(|i| &values[i]);
                }
                Node::Internal { keys, children } => {
                    // children[i] holds keys < keys[i]; keys equal to a separator go right.
                    let i = keys.partition_point(|k| k <= key);
                    node = &children[i];
                }
            }
        }
    }

    pub fn height(&self) -> usize {
        match self {
            Node::Leaf { .. } => 1,
            Node::Internal { children, .. } => 1 + children[0].height(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_through_boxes() {
        let leaf = |ks: &[u32]| {
            Box::new(Node::Leaf {
                keys: ks.to_vec(),
                values: ks.iter().map(|k| k * 10).collect(),
            })
        };
        let root = Node::Internal {
            keys: vec![10, 20],
            children: vec![leaf(&[1, 5]), leaf(&[10, 15]), leaf(&[20, 25])],
        };
        assert_eq!(root.get(&5), Some(&50));
        assert_eq!(root.get(&10), Some(&100));
        assert_eq!(root.get(&25), Some(&250));
        assert_eq!(root.get(&11), None);
        assert_eq!(root.height(), 2);
    }
}
