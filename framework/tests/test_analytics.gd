extends GutTest
## Analytics batching, backpressure, backend fan-out and session lifecycle.
## A fake backend captures flushed batches so assertions never touch disk.

class FakeBackend extends IAnalyticsBackend:
	var batches: Array = []

	func flush(events: Array[Dictionary]) -> void:
		batches.append(events.duplicate(true))


var _fake: RefCounted
var _original_backends: Array = []


func before_all() -> void:
	_fake = FakeBackend.new()
	_original_backends = Analytics._backends.duplicate()
	Analytics._timer.stop()
	Analytics.set_backends([_fake])


func after_all() -> void:
	Analytics.set_backends(_original_backends)


func before_each() -> void:
	Analytics.set_backends([_fake])
	Analytics._queue.clear()
	_fake.batches.clear()
	Analytics._session_id = ""


func test_track_below_threshold_does_not_flush() -> void:
	watch_signals(Analytics)
	for i in range(24):
		Analytics.track("pad_event_%d" % i, {"i": i})
	assert_signal_not_emitted(Analytics, "flushed", "queue below batch size must not flush")
	assert_eq(Analytics._queue.size(), 24, "all events queued")


func test_track_at_threshold_flushes_batch() -> void:
	for i in range(24):
		Analytics.track("pad_event_%d" % i, {"i": i})
	watch_signals(Analytics)
	Analytics.track("the_25th", {})
	assert_signal_emitted_with_parameters(Analytics, "flushed", [Analytics.FLUSH_BATCH_SIZE])
	assert_eq(_fake.batches.size(), 1, "exactly one batch flushed")
	assert_eq(_fake.batches[0].size(), Analytics.FLUSH_BATCH_SIZE, "batch holds the full threshold count")


func test_backpressure_flushes_and_drops_oldest() -> void:
	while Analytics._queue.size() < Analytics.MAX_QUEUE_SIZE:
		Analytics._queue.append({"name": "pad", "ts": 0, "session_id": "", "properties": {}})
	watch_signals(Analytics)
	Analytics.track("the_one", {})
	assert_signal_emitted_with_parameters(Analytics, "flushed", [Analytics.MAX_QUEUE_SIZE])
	assert_eq(_fake.batches.size(), 1, "backpressure flush sent one batch")
	assert_eq(_fake.batches[0].size(), Analytics.MAX_QUEUE_SIZE, "backpressure batch is full")
	assert_eq(Analytics._queue.size(), 1, "queue holds only the newest event after backpressure")
	assert_eq(Analytics._queue[0].get("name", ""), "the_one", "newest event survived backpressure")


func test_track_empty_name_is_ignored() -> void:
	watch_signals(Analytics)
	Analytics.track("")
	assert_push_warning("ignoring empty event name", "empty event name must warn")
	Analytics.flush()
	assert_eq(_fake.batches.size(), 0, "nothing was queued or flushed")


func test_multiple_backends_receive_same_batch() -> void:
	var fake2 := FakeBackend.new()
	Analytics.set_backends([_fake, fake2])
	Analytics.track("shared_event", {})
	Analytics.flush()
	assert_eq(_fake.batches.size(), 1, "first backend received a batch")
	assert_eq(fake2.batches.size(), 1, "second backend received a batch")
	var first: Dictionary = _fake.batches[0][0]
	var second: Dictionary = fake2.batches[0][0]
	assert_eq(first.get("name", ""), second.get("name", ""), "both backends got the same event name")


func test_set_backends_filters_non_backends() -> void:
	Analytics.set_backends([42, _fake])
	assert_push_warning("not IAnalyticsBackend", "non-backend entries must warn")
	assert_eq(Analytics._backends.size(), 1, "only real backends are kept")


func test_session_lifecycle_emits_and_tracks() -> void:
	watch_signals(EventBus)
	Analytics.start_session()
	var sid := Analytics.get_session_id()
	assert_false(sid.is_empty(), "session id generated")
	assert_signal_emitted_with_parameters(EventBus, "session_started", [sid])
	Analytics.start_session()
	assert_signal_emit_count(EventBus, "session_started", 1, "second start is a no-op")
	assert_eq(Analytics.get_session_id(), sid, "session id stable across duplicate start")
	watch_signals(Analytics)
	Analytics.end_session()
	assert_eq(Analytics.get_session_id(), "", "session cleared after end")
	assert_signal_emitted_with_parameters(EventBus, "session_ended", [sid])
	Analytics.flush()
	var found_start := false
	var found_end := false
	for batch in _fake.batches:
		for ev in batch:
			var name := str(ev.get("name", ""))
			if name == "session_start":
				found_start = true
			elif name == "session_end":
				found_end = true
	assert_true(found_start, "session_start event flushed to backend")
	assert_true(found_end, "session_end event flushed to backend")


func test_end_session_without_session_is_noop() -> void:
	watch_signals(EventBus)
	Analytics.end_session()
	assert_signal_not_emitted(EventBus, "session_ended", "end without a session must not emit")
