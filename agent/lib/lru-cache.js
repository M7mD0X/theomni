// =====================================================================
// Omni-IDE Agent — LRU Cache with TTL
// =====================================================================
// Proper LRU eviction using a doubly-linked list + Map for O(1) access.
// Evicts least-recently-used entries when capacity is exceeded.
// Entries also expire after CACHE_TTL_MS.
// =====================================================================

class _Node {
  final String key;
  dynamic value;
  int ts;
  _Node? prev;
  _Node? next;

  _Node(this.key, this.value, this.ts);
}

class LRUCache {
  final int maxSize;
  final int ttlMs;
  final Map<String, _Node> _map = {};
  _Node? _head; // most recently used
  _Node? _tail; // least recently used

  LRUCache({this.maxSize = 64, this.ttlMs = 5 * 60 * 1000});

  /// Get a cached value. Returns null if not found or expired.
  /// Moves the entry to the front (most recently used).
  dynamic get(String key) {
    final node = _map[key];
    if (node == null) return null;

    // Check TTL
    if (Date.now() - node.ts > ttlMs) {
      _removeNode(node);
      _map.remove(key);
      return null;
    }

    // Move to front
    _moveToFront(node);
    return node.value;
  }

  /// Set a cached value. Evicts LRU entries if over capacity.
  void set(String key, dynamic value) {
    final existing = _map[key];
    if (existing != null) {
      existing.value = value;
      existing.ts = Date.now();
      _moveToFront(existing);
      return;
    }

    // Evict if at capacity
    while (_map.length >= maxSize && _tail != null) {
      _map.remove(_tail!.key);
      _removeNode(_tail!);
    }

    final node = _Node(key, value, Date.now());
    _map[key] = node;
    _addToFront(node);
  }

  /// Remove a specific key.
  void delete(String key) {
    final node = _map.remove(key);
    if (node != null) _removeNode(node);
  }

  /// Clear all entries.
  void clear() {
    _map.clear();
    _head = null;
    _tail = null;
  }

  /// Current number of entries.
  int get length => _map.length;

  // ── Doubly-linked list operations ─────────────────────────────────────

  void _addToFront(_Node node) {
    node.prev = null;
    node.next = _head;
    if (_head != null) _head!.prev = node;
    _head = node;
    if (_tail == null) _tail = node;
  }

  void _removeNode(_Node node) {
    if (node.prev != null) {
      node.prev!.next = node.next;
    } else {
      _head = node.next;
    }
    if (node.next != null) {
      node.next!.prev = node.prev;
    } else {
      _tail = node.prev;
    }
    node.prev = null;
    node.next = null;
  }

  void _moveToFront(_Node node) {
    if (node == _head) return;
    _removeNode(node);
    _addToFront(node);
  }
}

// Simple Date.now() helper
class Date {
  static int now() => DateTime.now().millisecondsSinceEpoch;
}

module.exports = { LRUCache };
