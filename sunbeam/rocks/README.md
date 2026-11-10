# Local s390x rock staging

`build.py` and `tools/build_rock.sh` stage built `.rock` files here:

```text
rocks/rawfile-localpv_s390x.rock
rocks/<rock>_s390x.rock
```

The files are gitignored; only this README is tracked.

Phase 03 discovers `rocks/rawfile-localpv*.rock` automatically. For a generic
rock, use the printed OCI image reference with `juju attach-resource` or a
bundle resource entry.
