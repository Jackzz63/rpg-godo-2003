class_name AudioOutput
extends Node

@export var engine: Node = null

var _stream_player: AudioStreamPlayer = null
var _playback: AudioStreamGeneratorPlayback = null
var _connected_engine: Node = null
var _shutting_down := false

func _ready() -> void:
	if engine != null:
		attach(engine)

func _process(_delta: float) -> void:
	if (_shutting_down or _playback == null or not is_instance_valid(_playback)
			or _connected_engine == null or not is_instance_valid(_connected_engine)):
		return
	var perf_feed := ClientPerformance.begin()
	var frame_count: int = _connected_engine.audio_fill_playback(_playback)
	ClientPerformance.end(&"audio.feed_inclusive", perf_feed)
	if frame_count > 0:
		ClientPerformance.count_event(&"audio.frames", frame_count)
	elif frame_count < 0:
		# Do not decode again: a failed submission has already advanced the music.
		ClientPerformance.count_event(&"audio.submit_failures")
		Log.warn("AudioOutput: bulk audio submission failed; no retry")

func _exit_tree() -> void:
	_shutting_down = true
	detach()

func attach(e: Node) -> void:
	detach()
	_shutting_down = false
	_connected_engine = e
	var sample_rate: int = e.get_audio_sample_rate()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(sample_rate)
	gen.buffer_length = 0.1
	
	_stream_player = AudioStreamPlayer.new()
	_stream_player.stream = gen
	add_child(_stream_player)
	_stream_player.play()
	_playback = _stream_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if _playback != null:
		# AudioServer may still mix a stopped playback during its final fade-out.
		# Its generator pointer is non-owning, so keep the resource on the playback.
		_playback.set_meta(&"_generator_owner", gen)
	set_process(true)
	Log.info("AudioOutput: attached to %s (sample_rate=%d)" % [e.name, sample_rate])

func prepare_for_shutdown() -> void:
	_shutting_down = true
	detach()

func detach() -> void:
	set_process(false)
	_connected_engine = null
	_playback = null
	var player := _stream_player
	_stream_player = null
	if player != null and is_instance_valid(player):
		player.stop()
		player.stream = null
		player.queue_free()
