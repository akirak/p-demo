// Two heterogeneous replicas syncing only the fields they have in common
// (partial sync with shared-subset LWW).
//
// A logical record has fields a, b, c, d, but each peer stores only a subset:
//   PeerA: a, b, c      (a is private to PeerA)
//   PeerB:    b, c, d   (d is private to PeerB)
// The common subset (b, c) is synchronized; only that subset goes on the wire.
// Private fields never leave their peer, so a and d may diverge forever: only
// the shared subset is expected to converge.
//
// Domain rule: b <= c. A local edit is a multi-step transaction, so the shared
// subset can be temporarily invalid while a replica is in the Editing state.

type tVersion = (ts: int, rid: int);
type tShared = (b: int, c: int, ver: tVersion);   // the part both peers understand
type tObjA = (a: int, shared: tShared);           // PeerA's fields
type tObjB = (shared: tShared, d: int);           // PeerB's fields

event ePeer: machine;      // wire up the other replica
event eBeginEdit;
event eSetA: int;          // PeerA-only field
event eSetB: int;          // shared field
event eSetC: int;          // shared field
event eSetD: int;          // PeerB-only field
event eCommit;
event eSyncTick;           // "now may be a good time to sync" (from the environment)
event eSync: tShared;      // the actual sync message: only the shared subset

fun Newer(x: tVersion, y: tVersion): bool {
  return x.ts > y.ts || (x.ts == y.ts && x.rid > y.rid);
}

machine PeerA {
  var id: int;
  var peer: machine;
  var clock: int;
  var obj: tObjA;
  var sharedDirty: bool;   // did this transaction touch the shared subset?

  start state Init {
    entry (myId: int) {
      id = myId;
      clock = 0;
      obj = (a = 0, shared = (b = 0, c = 0, ver = (ts = 0, rid = 0)));
      sharedDirty = false;
    }
    on ePeer do (p: machine) { peer = p; goto Idle; }
  }

  // Idle: no open local transaction => syncing is allowed in both directions.
  state Idle {
    on eBeginEdit goto Editing;
    on eSyncTick do SendSync;
    on eSync do ApplySync;
  }

  // Editing: CONSTRAINT -- sync is postponed, not dropped.
  // `defer` keeps the events in the queue until a state that handles them.
  state Editing {
    defer eSync, eSyncTick;
    on eSetA do (v: int) { obj.a = v; }
    on eSetB do (v: int) { obj.shared.b = v; sharedDirty = true; }
    on eSetC do (v: int) { obj.shared.c = v; sharedDirty = true; }
    on eCommit do {
      assert obj.shared.b <= obj.shared.c,
        "commit with an invalid shared subset";
      // Private-only transactions do not advance the shared subset's version.
      if (sharedDirty) {
        clock = clock + 1;
        obj.shared.ver = (ts = clock, rid = id);
        sharedDirty = false;
      }
      goto Idle;
    }
  }

  fun SendSync() {
    // Partial payload: PeerB knows nothing about field a, so it is omitted.
    // Build a fresh value so later local edits cannot mutate what was sent.
    var out: tShared;
    out = (b = obj.shared.b, c = obj.shared.c, ver = obj.shared.ver);
    // The channel may lose or duplicate: 0, 1, or 2 copies get sent.
    if ($) { send peer, eSync, out; }
    if ($) { send peer, eSync, out; }
  }

  fun ApplySync(incoming: tShared) {
    if (Newer(incoming.ver, obj.shared.ver)) {
      // Merge the shared subset only; the private field a is untouched.
      obj.shared = incoming;
    }
    if (incoming.ver.ts > clock) {
      clock = incoming.ver.ts;
    }
  }
}

machine PeerB {
  var id: int;
  var peer: machine;
  var clock: int;
  var obj: tObjB;
  var sharedDirty: bool;

  start state Init {
    entry (myId: int) {
      id = myId;
      clock = 0;
      obj = (shared = (b = 0, c = 0, ver = (ts = 0, rid = 0)), d = 0);
      sharedDirty = false;
    }
    on ePeer do (p: machine) { peer = p; goto Idle; }
  }

  state Idle {
    on eBeginEdit goto Editing;
    on eSyncTick do SendSync;
    on eSync do ApplySync;
  }

  state Editing {
    defer eSync, eSyncTick;
    on eSetD do (v: int) { obj.d = v; }
    on eSetB do (v: int) { obj.shared.b = v; sharedDirty = true; }
    on eSetC do (v: int) { obj.shared.c = v; sharedDirty = true; }
    on eCommit do {
      assert obj.shared.b <= obj.shared.c,
        "commit with an invalid shared subset";
      if (sharedDirty) {
        clock = clock + 1;
        obj.shared.ver = (ts = clock, rid = id);
        sharedDirty = false;
      }
      goto Idle;
    }
  }

  fun SendSync() {
    // Partial payload: PeerA knows nothing about field d, so it is omitted.
    // Build a fresh value so later local edits cannot mutate what was sent.
    var out: tShared;
    out = (b = obj.shared.b, c = obj.shared.c, ver = obj.shared.ver);
    if ($) { send peer, eSync, out; }
    if ($) { send peer, eSync, out; }
  }

  fun ApplySync(incoming: tShared) {
    if (Newer(incoming.ver, obj.shared.ver)) {
      // Merge the shared subset only; the private field d is untouched.
      obj.shared = incoming;
    }
    if (incoming.ver.ts > clock) {
      clock = incoming.ver.ts;
    }
  }
}

// Safety: a half-edited (invalid) shared subset must never go on the wire.
spec NoPartialObjectOnWire observes eSync {
  start state Watching {
    on eSync do (o: tShared) {
      assert o.b <= o.c,
        format("partial shared subset leaked: b={0}, c={1}", o.b, o.c);
    }
  }
}

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
