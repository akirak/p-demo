// Two replicas of one object syncing full state (object-level LWW).
// Domain rule: a <= b. A local edit is a multi-step transaction, so the object
// can be temporarily invalid while a replica is in the Editing state.

type tVersion = (ts: int, rid: int);
type tObj = (a: int, b: int, ver: tVersion);

event ePeer: machine;      // wire up the other replica
event eBeginEdit;
event eSetA: int;
event eSetB: int;
event eCommit;
event eSyncTick;           // "now may be a good time to sync" (from the environment)
event eSync: tObj;         // the actual sync message: the full object

fun Newer(x: tVersion, y: tVersion): bool {
  return x.ts > y.ts || (x.ts == y.ts && x.rid > y.rid);
}

machine Replica {
  var id: int;
  var peer: machine;
  var clock: int;
  var obj: tObj;

  start state Init {
    entry (myId: int) {
      id = myId;
      clock = 0;
      obj = (a = 0, b = 0, ver = (ts = 0, rid = 0));
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
    on eSetB do (v: int) { obj.b = v; }
    on eCommit do {
      assert obj.a <= obj.b, "commit with an invalid object";
      clock = clock + 1;
      obj.ver = (ts = clock, rid = id);
      goto Idle;
    }
  }

  fun SendSync() {
    // The channel may lose or duplicate: 0, 1, or 2 copies get sent.
    // (Reordering across messages would need a separate Network machine.)
    if ($) { send peer, eSync, obj; }
    if ($) { send peer, eSync, obj; }
  }

  fun ApplySync(incoming: tObj) {
    if (Newer(incoming.ver, obj.ver)) {
      obj = incoming;
    }
    if (incoming.ver.ts > clock) {
      clock = incoming.ver.ts;
    }
  }
}

// Safety: a half-edited (invalid) object must never go on the wire.
spec NoPartialObjectOnWire observes eSync {
  start state Watching {
    on eSync do (o: tObj) {
      assert o.a <= o.b,
        format("partial object leaked: a={0}, b={1}", o.a, o.b);
    }
  }
}

// Environment: random edits and sync ticks on random replicas.
machine TestDriver {
  var r1: Replica;
  var r2: Replica;

  start state Run {
    entry {
      var i: int;
      r1 = new Replica(1);
      r2 = new Replica(2);
      send r1, ePeer, r2;
      send r2, ePeer, r1;
      i = 0;
      while (i < 4) {
        if ($) { EditAndMaybeSync(r1); } else { EditAndMaybeSync(r2); }
        i = i + 1;
      }
    }
  }

  fun EditAndMaybeSync(r: Replica) {
    var lo: int;
    var hi: int;
    lo = choose(3);
    hi = lo + choose(3);               // hi >= lo, so the final object is valid
    send r, eBeginEdit;
    // A background sync tick can arrive in the middle of the transaction.
    if ($) {
      send r, eSetA, lo;               // may leave the object invalid until eSetB
      send r, eSyncTick;
      send r, eSetB, hi;
    } else {
      send r, eSetB, hi;
      send r, eSyncTick;
      send r, eSetA, lo;
    }
    send r, eCommit;
    if ($) { send r, eSyncTick; }
  }
}

module SyncModule = { Replica, TestDriver };

test tcSync [main = TestDriver]:
  assert NoPartialObjectOnWire in SyncModule;
