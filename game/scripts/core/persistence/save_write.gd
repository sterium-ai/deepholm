class_name SaveWrite
extends RefCounted

## One save write running on a worker thread (A7): SaveIO.begin_write() stringifies the packed
## state on the calling thread, then this runs SaveIO.commit_body() (hash, write, read-back,
## rename) on its own Thread. The worker only sees the state text, the target path and
## SaveIO.content_check()'s plain data, never the state Dictionary or the world.
## is_done() polls; wait() joins and returns the same result SaveIO.write_atomic() would.
## Callbacks added with on_finished() run inside wait(), on the thread that calls it.

var _thread := Thread.new()
var _joined := false
var _result: Dictionary = {}
var _on_finished: Array[Callable] = []

func _init(path: String, body: String, check: Dictionary) -> void:
	_thread.start(SaveIO.commit_body.bind(path, body, check))

## True once the worker returned; wait() then does not block.
func is_done() -> bool:
	return _joined or not _thread.is_alive()

## Blocks until the write finished; {"ok", "code", "message", "file"} like write_atomic().
func wait() -> Dictionary:
	if not _joined:
		_result = _thread.wait_to_finish()
		_joined = true
		for callback in _on_finished:
			callback.call(_result)
		_on_finished.clear()
	return _result

## callback(result) runs once, inside the first wait(); at once when that already happened.
func on_finished(callback: Callable) -> void:
	if _joined:
		callback.call(_result)
		return
	_on_finished.append(callback)

## A handle dropped without wait() still joins its thread (Godot requires it).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _joined and _thread.is_started():
		_thread.wait_to_finish()
