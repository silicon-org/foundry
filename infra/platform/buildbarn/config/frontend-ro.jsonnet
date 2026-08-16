// Read-only frontend. Everything untrusted talks to this one. It may read the
// Action Cache and read and write the CAS, but it may not claim that an action
// produced a given result.
//
// Bazel's --noremote_upload_local_results is a convenience, not the control:
// the control is that this endpoint refuses the write regardless of what the
// client asks for.
(import 'frontend.libsonnet')({ deny: {} })
