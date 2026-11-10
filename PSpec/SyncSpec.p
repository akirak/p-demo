// Safety specifications for the partial-sync example in PSrc/Sync.p.

// Safety: a half-edited (invalid) shared subset must never go on the wire.
spec NoPartialObjectOnWire observes ePost {
  start state Watching {
    on ePost do (req: tPost) {
      assert req.body.b <= req.body.c,
        format("partial shared subset leaked: b={0}, c={1}", req.body.b, req.body.c);
    }
  }
}

// Safety: a version identifies exactly one committed shared subset.
// This is a stateful spec: it remembers the data seen for each version, so
// duplicates are fine but reusing a version with different data is not.
// (Message delivery may be out of order, so no ordering is assumed here.)
spec NoVersionReuse observes ePost {
  var seen: map[int, tShared];

  start state Watching {
    entry { seen = default(map[int, tShared]); }
    on ePost do (req: tPost) {
      var key: int;
      key = req.body.ver.ts * 10 + req.body.ver.rid;
      if (key in seen) {
        assert seen[key].b == req.body.b && seen[key].c == req.body.c,
          format("version ({0}, {1}) reused with different shared data",
                 req.body.ver.ts, req.body.ver.rid);
      } else {
        seen[key] = req.body;
      }
    }
  }
}

// Liveness: every POST is answered by exactly one response. The POST API is a
// request/response contract, so a caller must not be left without an answer.
spec EveryPostGetsResponse observes ePost, ePostResponse {
  var outstanding: int;

  start state Ready {
    entry { outstanding = 0; }
    on ePost do {
      outstanding = outstanding + 1;
      goto Awaiting;
    }
    on ePostResponse do { }
  }

  hot state Awaiting {
    on ePost do { outstanding = outstanding + 1; }
    on ePostResponse do {
      outstanding = outstanding - 1;
      if (outstanding == 0) {
        goto Ready;
      }
    }
  }
}

// Liveness: every sync tick must put at least one POST on the wire.
// SendSync sends 0, 1, or 2 POSTs, so a tick can be a no-op. Since there is
// no retry/anti-entropy, a dropped tick can leave the shared subset divergent
// forever. `eSyncTickDone` is test instrumentation: the peer sends it after
// handling a tick, so the monitor can tell "no message sent" from "not handled
// yet".
spec EverySyncTickSends observes eSyncTick, ePost, eSyncTickDone {
  var sawSync: bool;

  start state Waiting {
    on eSyncTick do {
      sawSync = false;
      goto Pending;
    }
    on ePost do { }
    on eSyncTickDone do { }
  }

  // While a tick is being handled, at least one POST must be observed.
  hot state Pending {
    on ePost do { sawSync = true; }
    on eSyncTickDone do {
      if (!sawSync) {
        goto Missed;
      }
      goto Waiting;
    }
    on eSyncTick do { }   // the test driver serializes ticks
  }

  // A tick was handled without producing any POST. Stay hot forever so the
  // checker reports a liveness violation at the end of the execution.
  hot state Missed {
    on eSyncTick do { }
    on ePost do { }
    on eSyncTickDone do { }
  }
}
