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
