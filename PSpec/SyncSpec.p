// Safety specifications for the partial-sync example in PSrc/Sync.p.

// Safety: a half-edited (invalid) shared subset must never go on the wire.
spec NoPartialObjectOnWire observes eSync {
  start state Watching {
    on eSync do (o: tShared) {
      assert o.b <= o.c,
        format("partial shared subset leaked: b={0}, c={1}", o.b, o.c);
    }
  }
}

// Safety: a version identifies exactly one committed shared subset.
// This is a stateful spec: it remembers the data seen for each version, so
// duplicates are fine but reusing a version with different data is not.
// (Message delivery may be out of order, so no ordering is assumed here.)
spec NoVersionReuse observes eSync {
  var seen: map[int, tShared];

  start state Watching {
    entry { seen = default(map[int, tShared]); }
    on eSync do (o: tShared) {
      var key: int;
      key = o.ver.ts * 10 + o.ver.rid;
      if (key in seen) {
        assert seen[key].b == o.b && seen[key].c == o.c,
          format("version ({0}, {1}) reused with different shared data",
                 o.ver.ts, o.ver.rid);
      } else {
        seen[key] = o;
      }
    }
  }
}

// Liveness: every sync tick must put at least one sync message on the wire.
// SendSync sends 0, 1, or 2 copies, so a tick can be a no-op. Since there is
// no retry/anti-entropy, a dropped tick can leave the shared subset divergent
// forever. `eSyncTickDone` is test instrumentation: the peer sends it after
// handling a tick, so the monitor can tell "no message sent" from "not handled
// yet".
spec EverySyncTickSends observes eSyncTick, eSync, eSyncTickDone {
  var sawSync: bool;

  start state Waiting {
    on eSyncTick do {
      sawSync = false;
      goto Pending;
    }
    on eSync do { }
    on eSyncTickDone do { }
  }

  // While a tick is being handled, at least one eSync must be observed.
  hot state Pending {
    on eSync do { sawSync = true; }
    on eSyncTickDone do {
      if (!sawSync) {
        goto Missed;
      }
      goto Waiting;
    }
    on eSyncTick do { }   // the test driver serializes ticks
  }

  // A tick was handled without producing any sync message. Stay hot forever
  // so the checker reports a liveness violation at the end of the execution.
  hot state Missed {
    on eSyncTick do { }
    on eSync do { }
    on eSyncTickDone do { }
  }
}
