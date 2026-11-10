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
      send pa, ePeer, (peer = pb, driver = this);
      send pb, ePeer, (peer = pa, driver = this);
      i = 0;
      while (i < 4) {
        if ($) { EditA(pa); } else { EditB(pb); }
        i = i + 1;
      }
    }
    on eReady do { }
    on eSyncTickDone do { }
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

// Stress driver for the best-effort sender: tick PeerA many times, waiting for
// each tick to be handled before issuing the next one. This lets the liveness
// spec pair the POSTs a tick actually sent with that tick.
machine SyncLossDriver {
  var pa: PeerA;
  var pb: PeerB;
  var ready: int;
  var ticksLeft: int;

  start state Init {
    entry {
      pa = new PeerA(1);
      pb = new PeerB(2);
      ready = 0;
      send pa, ePeer, (peer = pb, driver = this);
      send pb, ePeer, (peer = pa, driver = this);
    }

    on eReady do {
      ready = ready + 1;
      if (ready == 2) {
        ticksLeft = 20;
        ticksLeft = ticksLeft - 1;
        send pa, eSyncTick;
        goto Run;
      }
    }
  }

  state Run {
    on eSyncTickDone do {
      if (ticksLeft > 0) {
        ticksLeft = ticksLeft - 1;
        send pa, eSyncTick;
      }
    }
  }
}

// Exercises the explicit POST API on both peers. PeerA receives the POST while
// a local transaction is open, so the request must be deferred (not dropped)
// and answered after the commit. PeerB is idle, so it answers immediately.
machine PostDriver {
  var pa: PeerA;
  var pb: PeerB;
  var ready: int;
  var responses: int;

  start state Init {
    entry {
      pa = new PeerA(1);
      pb = new PeerB(2);
      ready = 0;
      responses = 0;
      send pa, ePeer, (peer = pb, driver = this);
      send pb, ePeer, (peer = pa, driver = this);
    }

    on eReady do {
      ready = ready + 1;
      if (ready == 2) {
        send pa, eBeginEdit;
        send pa, eSetB, 1;
        send pa, eSetC, 2;
        send pa, ePost,
             (from = this, body = (b = 3, c = 4, ver = (ts = 1, rid = 10)));
        send pa, eCommit;

        send pb, ePost,
             (from = this, body = (b = 5, c = 6, ver = (ts = 1, rid = 20)));
        goto Run;
      }
    }
  }

  state Run {
    on ePostResponse do (resp: tPostResponse) {
      assert resp.accepted, "a newer POST must be accepted";
      responses = responses + 1;
      assert responses <= 2, "each POST must be answered exactly once";
    }
    on eSyncTickDone do { }
  }
}

module SyncModule = { PeerA, PeerB, TestDriver, SyncLossDriver, PostDriver };

test tcSync [main = TestDriver]:
  assert NoPartialObjectOnWire in SyncModule;

test tcNoVersionReuse [main = TestDriver]:
  assert NoVersionReuse in SyncModule;

test tcPostApi [main = PostDriver]:
  assert EveryPostGetsResponse in SyncModule;

// This test is expected to fail: some sync tick sends zero messages, and there
// is no retry, so the shared subset is not guaranteed to converge.
test tcLostTick [main = SyncLossDriver]:
  assert EverySyncTickSends in SyncModule;
