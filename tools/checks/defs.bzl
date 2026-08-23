"""Constants the checks share with tools/githooks/pre-commit.

The hook greps `MAX_FILE_BYTES` out of this file rather than repeating the
number, so the check a commit runs and the check CI runs cannot disagree about
where the line is. Keep the assignment on one line and in this shape.
"""

# 1 MiB. The largest tracked file today is a 278 KB Grafana dashboard, so this is
# roughly four times the biggest thing anyone has deliberately committed -- loose
# enough not to argue with, tight enough that a vendored tarball or a captured
# waveform trips it.
MAX_FILE_BYTES = 1048576
