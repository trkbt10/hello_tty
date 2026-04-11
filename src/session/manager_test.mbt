///|
/// Tests for session lifecycle — verifying child processes are properly
/// terminated and reaped when sessions are destroyed.

///|
test "destroy_session kills child process" {
  let sm = SessionManager::new()
  let (session_id, master_fd) = sm.create_session(24, 80)
  // Session should be created with a valid master fd
  assert_true(master_fd >= 0)
  // Child process should be alive
  assert_true(sm.is_child_alive(session_id))
  // Destroy the session
  sm.destroy_session(session_id)
  // After destroy, the session should be gone from the map,
  // and is_child_alive returns false (session not found).
  assert_true(!sm.is_child_alive(session_id))
}

///|
test "destroy_all kills all child processes" {
  let sm = SessionManager::new()
  let (id1, fd1) = sm.create_session(24, 80)
  let (id2, fd2) = sm.create_session(24, 80)
  assert_true(fd1 >= 0)
  assert_true(fd2 >= 0)
  assert_true(sm.is_child_alive(id1))
  assert_true(sm.is_child_alive(id2))
  sm.destroy_all()
  assert_true(!sm.is_child_alive(id1))
  assert_true(!sm.is_child_alive(id2))
  assert_eq(sm.count(), 0)
}

///|
test "destroy_session does not leave zombie" {
  let sm = SessionManager::new()
  let (session_id, _) = sm.create_session(24, 80)
  // Get the child pid before destroying via the public accessor
  let pid = sm.get_child_pid(session_id)
  assert_true(pid > 0)
  sm.destroy_session(session_id)
  // The process should not be alive after destroy + reap.
  // kill(pid, 0) returns -1 with ESRCH if the process doesn't exist.
  assert_eq(@pty_ffi.pty_is_pid_alive(pid), 0)
}
