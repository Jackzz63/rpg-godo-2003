#ifndef EASYRPG_RPGMAKER_PLAYER_H
#define EASYRPG_RPGMAKER_PLAYER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/audio_stream_generator_playback.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <array>

#include <memory>
#include <functional>
#include <map>
#include <string>
#include <cstdint>
#include <vector>

#include "multiplayer/mp_callbacks.h"

class GodotUi; // fwd from ynoengine

namespace godot {

class RPGMakerPlayer : public Node {
	GDCLASS(RPGMakerPlayer, Node)

public:
	RPGMakerPlayer();
	~RPGMakerPlayer() override;

	void set_game_path(const String& path);
	String get_game_path() const;
	Dictionary inspect_game_directory(const String& path) const;

	void start_game();
	void stop_game();
	Ref<ImageTexture> get_frame_texture() const;
	bool is_running() const;

	void open_save_menu();

	void open_load_menu();

	void open_debug_menu();

	bool set_resolution(int width, int height);

	int get_screen_width() const;

	int get_screen_height() const;

	bool is_map_ready() const;
	int get_current_map_id() const;
	String get_original_game_title() const;
	String get_current_language_code() const;
	int get_current_player_x() const;
	int get_current_player_y() const;
	Ref<ImageTexture> get_current_system_texture() const;
	Ref<ImageTexture> get_system_texture(const String& system_name) const;
	int get_current_system_stretch() const;
	Ref<ImageTexture> render_game_window_with_system(
		const String& system_name, int width, int height, int stretch_mode) const;
	Ref<ImageTexture> render_character_avatar(
		const String& sprite_name, int sprite_index, int facing) const;
	Ref<ImageTexture> render_character_profile(
		const String& sprite_name, int sprite_index) const;
	Dictionary render_current_game_text(const String& text, int max_width) const;
	Dictionary render_game_text_with_system(
		const String& text, const String& system_name, int max_width, int color_index) const;
	void mp_set_session_active(bool active);
	void mp_notify_room_ready();
	bool mp_apply_server_variables(const Dictionary& values);
	void mp_clear_server_variables();

	PackedFloat32Array audio_pull_frames(int frame_count);
	// Main-thread, single-producer API. Playback is borrowed for this call only.
	// Returns submitted frames, 0 when idle/full, or -1 on failure (no retry).
	int audio_fill_playback(const Ref<AudioStreamGeneratorPlayback>& playback);
	void set_performance_enabled(bool enabled);
	PackedInt64Array take_performance_counters();

	int get_audio_sample_rate() const;
	void set_native_midi_muted(bool muted);
	bool is_native_midi_muted() const;

	void inject_key(int easyrpg_key_id, bool pressed);

	void set_mp_callbacks(MpCallbacks cbs) { mp_callbacks_ = std::move(cbs); }
	MpCallbacks& get_mp_callbacks() { return mp_callbacks_; }

	void mp_add_player(int id, int x, int y, const String& sprite_name, int sprite_index, int facing, int speed);

	void mp_remove_player(int id);
	void mp_clear_remote_players_immediate();
	void mp_clear_remote_player_objects_immediate();

	void mp_move_player(int id, int x, int y);
	void mp_jump_player(int id, int x, int y);

	void mp_set_player_facing(int id, int facing);

	void mp_set_player_speed(int id, int speed);

	void mp_set_player_sprite(int id, const String& name, int index);

	void mp_set_player_transparency(int id, int transparency);

	void mp_set_player_hidden(int id, bool hidden);

	void mp_flash_player(int id, int r, int g, int b, int power, int frames);

	void mp_play_se(const String& name, int volume, int tempo, int balance);

	void mp_sync_local_player();

	void mp_set_player_name(int id, const String& name);

	void mp_set_player_system_graphic(int id, const String& sys_name);

	void mp_set_nametag_mode(int mode);
	Ref<ImageTexture> mp_render_nametag_mode_preview(int mode) const;

	void mp_set_room(int room_id);

	void mp_set_room_id(int room_id);

	void _ready() override;

	void _process(double delta) override;

	void _notification(int p_what);

protected:
	static void _bind_methods();

private:
	String game_path_;
	bool performance_enabled_ = false;
	// usec, calls pairs: update, draw (inclusive), conversion, upload, audio pull,
	// audio decode (including native mixer copy), logical update count (zero usec).
	// Tail counters: skipped draws, forced draws without a logic tick, committed frames.
	// Appended pairs: audio conversion, bulk push, native feed (inclusive).
	std::array<int64_t, 23> performance_counters_{};
	std::vector<int16_t> audio_pcm_;
	PackedVector2Array audio_frames_;
	bool engine_running_ = false;
	bool native_midi_muted_ = false;
	bool frame_dirty_ = true;
	bool player_initialized_ = false;
	GodotUi* godot_ui_ = nullptr;
	Ref<ImageTexture> frame_texture_;
	Ref<Image> frame_image_;
	MpCallbacks mp_callbacks_;
	bool server_variables_active_ = false;
	std::map<int, int> server_variables_;

	void enforce_server_variables();
	void cleanup_engine();
	void on_frame_ready(const uint8_t* pixels, int width, int height, int pitch);
};

} // namespace godot

#endif
