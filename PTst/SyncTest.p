// Test environment and test cases for the partial-sync example.

// Environment: random edits and sync ticks on random replicas.
machine TestDriver {
  var pa: PeerA;
  var pb: PeerB;

  start state Run {
    entry {
      var i: int;
      pa = new PeerA(1);
      pb = new PeerB(2);
      send pa, ePeer, pb;
      send pb, ePeer, pa;
      i = 0;
      while (i < 4) {
        if ($) { EditA(pa); } else { EditB(pb); }
        i = i + 1;
      }
    }
  }

  // PeerA edits its private field a and the shared subset (b, c).
  fun EditA(p: PeerA) {
    var lo: int;
    var hi: int;
    lo = choose(3);
    hi = lo + choose(3);               // hi >= lo, so the final subset is valid
    send p, eBeginEdit;
    // A background sync tick can arrive in the middle of the transaction.
    if ($) {
      send p, eSetB, hi;               // may leave b > c until eSetC
      send p, eSyncTick;
      send p, eSetC, hi;
      send p, eSetB, lo;
    } else {
      send p, eSetC, lo;               // may leave b > c until eSetB
      send p, eSyncTick;
      send p, eSetB, lo;
      send p, eSetC, hi;
    }
    send p, eSetA, choose(3);
    send p, eCommit;
    if ($) { send p, eSyncTick; }
  }

  // PeerB edits its private field d and the shared subset (b, c).
  fun EditB(p: PeerB) {
    var lo: int;
    var hi: int;
    lo = choose(3);
    hi = lo + choose(3);
    send p, eBeginEdit;
    if ($) {
      send p, eSetB, hi;
      send p, eSyncTick;
      send p, eSetC, hi;
      send p, eSetB, lo;
    } else {
      send p, eSetC, lo;
      send p, eSyncTick;
      send p, eSetB, lo;
      send p, eSetC, hi;
    }
    send p, eSetD, choose(3);
    send p, eCommit;
    if ($) { send p, eSyncTick; }
  }
}

module SyncModule = { PeerA, PeerB, TestDriver };

test tcSync [main = TestDriver]:
  assert NoPartialObjectOnWire in SyncModule;

test tcNoVersionReuse [main = TestDriver]:
  assert NoVersionReuse in SyncModule;
