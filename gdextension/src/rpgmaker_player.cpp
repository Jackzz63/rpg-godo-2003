#include "rpgmaker_player.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/font_file.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>

#include "baseui.h"
#include "bitmap.h"
#include "cache.h"
#include "filefinder.h"
#include "filesystem_native.h"
#include "font.h"
#include "game_clock.h"
#include "graphics.h"
#include "game_map.h"
#include "game_system.h"
#include "game_variables.h"
#include "instrumentation.h"
#include "input.h"
#include "message_overlay.h"
#include "main_data.h"
#include "player.h"
#include "scene.h"
#include "output.h"
#include "scene_debug.h"
#include "scene_load.h"
#include "scene_save.h"
#include "sprite_character.h"
#include "transition.h"
#include "text.h"

#include "multiplayer/game_multiplayer.h"

#include "platform/godot/ui.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>
#include <string>

namespace godot {

namespace {

Ref<ImageTexture> bitmap_to_godot_texture(const BitmapRef& bitmap) {
	if (!bitmap || !bitmap->pixels() || bitmap->width() <= 0 || bitmap->height() <= 0 || bitmap->bpp() != 4) {
		return Ref<ImageTexture>();
	}

	const int width = bitmap->width();
	const int height = bitmap->height();
	const int pitch = bitmap->pitch();
	const auto* pixels = static_cast<const uint8_t*>(bitmap->pixels());
	PackedByteArray data;
	data.resize(width * height * 4);
	uint8_t* dst = data.ptrw();

	for (int y = 0; y < height; ++y) {
		const uint8_t* src_row = pixels + y * pitch;
		uint8_t* dst_row = dst + y * width * 4;
		for (int x = 0; x < width; ++x) {
			const uint8_t b = src_row[x * 4 + 0];
			const uint8_t g = src_row[x * 4 + 1];
			const uint8_t r = src_row[x * 4 + 2];
			const uint8_t a = src_row[x * 4 + 3];

			// ynoengine stores alpha-bearing bitmaps premultiplied. Godot's
			// ImageTexture expects straight RGBA, so restore the source colour to
			// keep glyph edges and translucent system graphics from darkening.
			auto unpremultiply = [a](uint8_t channel) -> uint8_t {
				if (a == 0 || a == 255) return channel;
				return static_cast<uint8_t>(std::min(255, (static_cast<int>(channel) * 255 + a / 2) / a));
			};
			dst_row[x * 4 + 0] = unpremultiply(r);
			dst_row[x * 4 + 1] = unpremultiply(g);
			dst_row[x * 4 + 2] = unpremultiply(b);
			dst_row[x * 4 + 3] = a;
		}
	}

	Ref<Image> image = Image::create(width, height, false, Image::FORMAT_RGBA8);
	if (image.is_null()) return Ref<ImageTexture>();
	image->set_data(width, height, false, Image::FORMAT_RGBA8, data);
	return ImageTexture::create_from_image(image);
}

Dictionary render_text_bitmap(const String& text, int max_width,
		const BitmapRef& system, const FontRef& font, int color_index) {
	Dictionary result;
	// Location JSON is data-driven and will eventually support user sources.
	// Cap both the Unicode input and output surface so malformed data cannot
	// request an excessive native allocation while the visible result remains
	// identical to YNO's single-line, right-clipped banner.
	const String safe_text = text.substr(0, 512);
	const CharString utf8 = safe_text.utf8();
	const std::string text_utf8(utf8.get_data(), utf8.length());
	const Rect measured = Text::GetSize(*font, text_utf8);
	const int surface_width = std::max(1, std::min({ measured.width + 1, max_width, 4096 }));
	const int surface_height = std::max(1, std::min(measured.height + 1, 64));

	BitmapRef rendered = Bitmap::Create(surface_width, surface_height, true);
	if (!rendered || !rendered->pixels()) return result;
	rendered->Clear();
	Text::Draw(
		*rendered,
		0,
		0,
		*font,
		*system,
		color_index,
		text_utf8,
		Text::AlignLeft
	);

	Ref<ImageTexture> texture = bitmap_to_godot_texture(rendered);
	if (texture.is_null()) return Dictionary();
	result["texture"] = texture;
	result["width"] = surface_width;
	result["height"] = surface_height;
	result["full_width"] = measured.width + 1;
	return result;
}

std::vector<uint8_t> load_font_resource_bytes(const String& path) {
	Ref<FontFile> font_file = ResourceLoader::get_singleton()->load(path);
	if (font_file.is_null()) {
		return {};
	}
	const PackedByteArray data = font_file->get_data();
	if (data.is_empty()) {
		return {};
	}
	return std::vector<uint8_t>(data.ptr(), data.ptr() + data.size());
}

} // namespace

namespace {
class PerformanceScope {
	using Clock = std::chrono::steady_clock;
	int64_t* counters_;
	Clock::time_point start_;
public:
	PerformanceScope(bool enabled, int64_t* counters) : counters_(enabled ? counters : nullptr) {
		if (counters_) start_ = Clock::now();
	}
	void finish() {
		if (!counters_) return;
		counters_[0] += std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start_).count();
		++counters_[1];
		counters_ = nullptr;
	}
	~PerformanceScope() { finish(); }
};
}

RPGMakerPlayer::RPGMakerPlayer() {}

void RPGMakerPlayer::set_performance_enabled(bool enabled) {
	performance_enabled_ = enabled;
	performance_counters_.fill(0);
}

PackedInt64Array RPGMakerPlayer::take_performance_counters() {
	PackedInt64Array result;
	result.resize(performance_counters_.size());
	std::copy(performance_counters_.begin(), performance_counters_.end(), result.ptrw());
	performance_counters_.fill(0);
	return result;
}

RPGMakerPlayer::~RPGMakerPlayer() {
	stop_game();
}

void RPGMakerPlayer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_performance_enabled", "enabled"), &RPGMakerPlayer::set_performance_enabled);
	ClassDB::bind_method(D_METHOD("take_performance_counters"), &RPGMakerPlayer::take_performance_counters);
	ClassDB::bind_method(D_METHOD("set_game_path", "path"), &RPGMakerPlayer::set_game_path);
	ClassDB::bind_method(D_METHOD("get_game_path"), &RPGMakerPlayer::get_game_path);
	ClassDB::bind_method(D_METHOD("inspect_game_directory", "path"), &RPGMakerPlayer::inspect_game_directory);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "game_path", PROPERTY_HINT_DIR), "set_game_path", "get_game_path");

	ClassDB::bind_method(D_METHOD("start_game"), &RPGMakerPlayer::start_game);
	ClassDB::bind_method(D_METHOD("stop_game"), &RPGMakerPlayer::stop_game);
	ClassDB::bind_method(D_METHOD("open_save_menu"), &RPGMakerPlayer::open_save_menu);
	ClassDB::bind_method(D_METHOD("open_load_menu"), &RPGMakerPlayer::open_load_menu);
	ClassDB::bind_method(D_METHOD("open_debug_menu"), &RPGMakerPlayer::open_debug_menu);
	ClassDB::bind_method(D_METHOD("get_frame_texture"), &RPGMakerPlayer::get_frame_texture);
	ClassDB::bind_method(D_METHOD("is_running"), &RPGMakerPlayer::is_running);
	ClassDB::bind_method(D_METHOD("is_map_ready"), &RPGMakerPlayer::is_map_ready);
	ClassDB::bind_method(D_METHOD("get_current_map_id"), &RPGMakerPlayer::get_current_map_id);
	ClassDB::bind_method(D_METHOD("get_original_game_title"), &RPGMakerPlayer::get_original_game_title);
	ClassDB::bind_method(D_METHOD("get_current_language_code"), &RPGMakerPlayer::get_current_language_code);
	ClassDB::bind_method(D_METHOD("get_current_player_x"), &RPGMakerPlayer::get_current_player_x);
	ClassDB::bind_method(D_METHOD("get_current_player_y"), &RPGMakerPlayer::get_current_player_y);
	ClassDB::bind_method(D_METHOD("get_current_system_texture"), &RPGMakerPlayer::get_current_system_texture);
	ClassDB::bind_method(D_METHOD("get_system_texture", "system_name"), &RPGMakerPlayer::get_system_texture);
	ClassDB::bind_method(D_METHOD("get_current_system_stretch"), &RPGMakerPlayer::get_current_system_stretch);
	ClassDB::bind_method(
		D_METHOD("render_game_window_with_system", "system_name", "width", "height", "stretch_mode"),
		&RPGMakerPlayer::render_game_window_with_system
	);
	ClassDB::bind_method(
		D_METHOD("render_character_avatar", "sprite_name", "sprite_index", "facing"),
		&RPGMakerPlayer::render_character_avatar
	);
	ClassDB::bind_method(
		D_METHOD("render_character_profile", "sprite_name", "sprite_index"),
		&RPGMakerPlayer::render_character_profile
	);
	ClassDB::bind_method(
		D_METHOD("render_current_game_text", "text", "max_width"),
		&RPGMakerPlayer::render_current_game_text
	);
	ClassDB::bind_method(
		D_METHOD("render_game_text_with_system", "text", "system_name", "max_width", "color_index"),
		&RPGMakerPlayer::render_game_text_with_system,
		DEFVAL(0)
	);
	ClassDB::bind_method(D_METHOD("mp_set_session_active", "active"), &RPGMakerPlayer::mp_set_session_active);
	ClassDB::bind_method(D_METHOD("mp_notify_room_ready"), &RPGMakerPlayer::mp_notify_room_ready);
	ClassDB::bind_method(D_METHOD("mp_apply_server_variables", "values"), &RPGMakerPlayer::mp_apply_server_variables);
	ClassDB::bind_method(D_METHOD("mp_clear_server_variables"), &RPGMakerPlayer::mp_clear_server_variables);
	ClassDB::bind_method(D_METHOD("inject_key", "easyrpg_key_id", "pressed"), &RPGMakerPlayer::inject_key);

	ClassDB::bind_method(
		D_METHOD("mp_add_player", "id", "x", "y", "sprite_name", "sprite_index", "facing", "speed"),
		&RPGMakerPlayer::mp_add_player
	);
	ClassDB::bind_method(D_METHOD("mp_remove_player", "id"), &RPGMakerPlayer::mp_remove_player);
	ClassDB::bind_method(D_METHOD("mp_clear_remote_players_immediate"), &RPGMakerPlayer::mp_clear_remote_players_immediate);
	ClassDB::bind_method(
		D_METHOD("mp_clear_remote_player_objects_immediate"),
		&RPGMakerPlayer::mp_clear_remote_player_objects_immediate
	);
	ClassDB::bind_method(D_METHOD("mp_move_player", "id", "x", "y"), &RPGMakerPlayer::mp_move_player);
	ClassDB::bind_method(D_METHOD("mp_jump_player", "id", "x", "y"), &RPGMakerPlayer::mp_jump_player);
	ClassDB::bind_method(D_METHOD("mp_set_player_facing", "id", "facing"), &RPGMakerPlayer::mp_set_player_facing);
	ClassDB::bind_method(D_METHOD("mp_set_player_speed", "id", "speed"), &RPGMakerPlayer::mp_set_player_speed);
	ClassDB::bind_method(D_METHOD("mp_set_player_sprite", "id", "name", "index"), &RPGMakerPlayer::mp_set_player_sprite);
	ClassDB::bind_method(D_METHOD("mp_set_player_transparency", "id", "transparency"), &RPGMakerPlayer::mp_set_player_transparency);
	ClassDB::bind_method(D_METHOD("mp_set_player_hidden", "id", "hidden"), &RPGMakerPlayer::mp_set_player_hidden);
	ClassDB::bind_method(D_METHOD("mp_flash_player", "id", "r", "g", "b", "power", "frames"), &RPGMakerPlayer::mp_flash_player);
	ClassDB::bind_method(D_METHOD("mp_sync_local_player"), &RPGMakerPlayer::mp_sync_local_player);
	ClassDB::bind_method(D_METHOD("mp_set_room", "room_id"), &RPGMakerPlayer::mp_set_room);
	ClassDB::bind_method(D_METHOD("mp_set_room_id", "room_id"), &RPGMakerPlayer::mp_set_room_id);
	ClassDB::bind_method( D_METHOD("mp_play_se", "name", "volume", "tempo", "balance"), &RPGMakerPlayer::mp_play_se);
	ClassDB::bind_method(D_METHOD("mp_set_player_name", "id", "name"), &RPGMakerPlayer::mp_set_player_name);
	ClassDB::bind_method(D_METHOD("mp_set_player_system_graphic", "id", "sys_name"), &RPGMakerPlayer::mp_set_player_system_graphic);
	ClassDB::bind_method(D_METHOD("mp_set_nametag_mode", "mode"), &RPGMakerPlayer::mp_set_nametag_mode);
	ClassDB::bind_method(
		D_METHOD("mp_render_nametag_mode_preview", "mode"),
		&RPGMakerPlayer::mp_render_nametag_mode_preview);

	ClassDB::bind_method(D_METHOD("set_resolution", "width", "height"), &RPGMakerPlayer::set_resolution);
	ClassDB::bind_method(D_METHOD("get_screen_width"), &RPGMakerPlayer::get_screen_width);
	ClassDB::bind_method(D_METHOD("get_screen_height"), &RPGMakerPlayer::get_screen_height);

	ClassDB::bind_method(D_METHOD("audio_pull_frames", "frame_count"), &RPGMakerPlayer::audio_pull_frames);
	ClassDB::bind_method(D_METHOD("audio_fill_playback", "playback"), &RPGMakerPlayer::audio_fill_playback);
	ClassDB::bind_method(D_METHOD("get_audio_sample_rate"), &RPGMakerPlayer::get_audio_sample_rate);
	ClassDB::bind_method(D_METHOD("set_native_midi_muted", "muted"), &RPGMakerPlayer::set_native_midi_muted);
	ClassDB::bind_method(D_METHOD("is_native_midi_muted"), &RPGMakerPlayer::is_native_midi_muted);

	ADD_SIGNAL(
		MethodInfo("resolution_changed",
			PropertyInfo(Variant::INT, "width"),
			PropertyInfo(Variant::INT, "height")
		)
	);
	ADD_SIGNAL(
		MethodInfo("video_settings_changed",
			PropertyInfo(Variant::INT, "scaling_mode"),
			PropertyInfo(Variant::BOOL, "stretch"),
			PropertyInfo(Variant::INT, "screen_scale")
		)
	);

	ADD_SIGNAL(
		MethodInfo("player_moved",
			PropertyInfo(Variant::INT, "x"),
			PropertyInfo(Variant::INT, "y")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_facing_changed",
			PropertyInfo(Variant::INT, "dir")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_speed_changed",
			PropertyInfo(Variant::INT, "speed")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_sprite_changed",
			PropertyInfo(Variant::STRING, "name"), PropertyInfo(Variant::INT, "index")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_jumped",
			PropertyInfo(Variant::INT, "x"), PropertyInfo(Variant::INT, "y")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_flashed",
			PropertyInfo(Variant::INT, "r"), PropertyInfo(Variant::INT, "g"),
			PropertyInfo(Variant::INT, "b"), PropertyInfo(Variant::INT, "power"),
			PropertyInfo(Variant::INT, "frames")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_transparency_changed",
			PropertyInfo(Variant::INT, "transparency")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_hidden_changed",
			PropertyInfo(Variant::BOOL, "hidden")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_teleported",
			PropertyInfo(Variant::INT, "map_id"),
			PropertyInfo(Variant::INT, "x"), PropertyInfo(Variant::INT, "y")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_se_played",
			PropertyInfo(Variant::STRING, "name"), PropertyInfo(Variant::INT, "volume"),
			PropertyInfo(Variant::INT, "tempo"),  PropertyInfo(Variant::INT, "balance")
		)
	);
	ADD_SIGNAL(
		MethodInfo("player_system_changed",
			PropertyInfo(Variant::STRING, "sys_name")
		)
	);
	ADD_SIGNAL(
		MethodInfo("map_changed",
			PropertyInfo(Variant::INT, "map_id")
		)
	);
	ADD_SIGNAL(
		MethodInfo("switch_set",
			PropertyInfo(Variant::INT, "switch_id"), PropertyInfo(Variant::INT, "value")
		)
	);
	ADD_SIGNAL(
		MethodInfo("variable_set",
			PropertyInfo(Variant::INT, "var_id"), PropertyInfo(Variant::INT, "value")
		)
	);
	ADD_SIGNAL(
		MethodInfo("event_triggered",
			PropertyInfo(Variant::INT, "event_id"), PropertyInfo(Variant::BOOL, "action")
		)
	);
}

void RPGMakerPlayer::_ready() {
	frame_texture_ = ImageTexture::create_from_image(
		Image::create(320, 240, false, Image::FORMAT_RGBA8));
}

void RPGMakerPlayer::_process(double) {
	if (!engine_running_) return;
	assert(Scene::instance);

	try {
		const auto frame_time = Game_Clock::now();
		PerformanceScope update_scope(performance_enabled_, performance_counters_.data());
		Game_Clock::OnNextFrame(frame_time);

		Player::UpdateInput();

		if (!DisplayUi->ProcessEvents()) {
			Scene::PopUntil(Scene::Null);
			stop_game();
			return;
		}

		int num_updates = 0;
		while (Game_Clock::NextGameTimeStep()) {
			if (num_updates > 0) {
				Player::UpdateInput();
				if (!DisplayUi->ProcessEvents()) {
					Scene::PopUntil(Scene::Null);
					stop_game();
					return;
				}
			}
			Scene::old_instances.clear();
			Scene::instance->MainFunction();
			enforce_server_variables();

			Graphics::GetMessageOverlay().Update();

			++num_updates;
		}

		if (num_updates == 0) {
			Input::UpdateSystem();
		}

		// Maintain system overlays even when the 60 Hz game clock has no update.
		frame_dirty_ = Graphics::Update() || frame_dirty_;
		frame_dirty_ = frame_dirty_ || frame_image_.is_null()
			|| frame_image_->get_width() != godot_ui_->GetFrameWidth()
			|| frame_image_->get_height() != godot_ui_->GetFrameHeight();
		update_scope.finish();
		if (performance_enabled_) performance_counters_[13] += num_updates;
		if (num_updates > 0 || frame_dirty_) {
			if (performance_enabled_ && num_updates == 0) ++performance_counters_[15];
			frame_dirty_ = false;
			PerformanceScope draw_scope(performance_enabled_, performance_counters_.data() + 2);
			Graphics::Draw(*DisplayUi->GetDisplaySurface());
			DisplayUi->UpdateDisplay();
		} else if (performance_enabled_) {
			++performance_counters_[14];
		}
		Scene::old_instances.clear();

		if (Player::exit_flag ||
			(!Transition::instance().IsActive() && Scene::instance->type == Scene::Null)) {
			stop_game();
		}
	} catch (const std::exception& e) {
		UtilityFunctions::push_error(
			String("RPGMakerPlayer: engine error in _process: ") + String(e.what()));
		cleanup_engine();
	} catch (...) {
		UtilityFunctions::push_error("RPGMakerPlayer: unknown engine error in _process().");
		cleanup_engine();
	}
}

void RPGMakerPlayer::_notification(int p_what) {
	if (p_what == NOTIFICATION_EXIT_TREE) {
		stop_game();
	}
}

void RPGMakerPlayer::set_game_path(const String& path) { game_path_ = path; }
String RPGMakerPlayer::get_game_path() const { return game_path_; }

Dictionary RPGMakerPlayer::inspect_game_directory(const String& path) const {
	Dictionary result;
	result["ok"] = false;
	result["error"] = String::utf8("未识别到 RPG Maker 2000/2003 游戏文件。");
	if (engine_running_ || player_initialized_) {
		result["error"] = String::utf8("请先返回启动器，再选择游戏目录。");
		return result;
	}
	if (!path.is_absolute_path() || path.contains("://") || path.begins_with("//") ||
		!DirAccess::dir_exists_absolute(path)) {
		result["error"] = String::utf8("请选择可读取的真实游戏目录。");
		return result;
	}
	// Main-thread, pre-launch inspection. DirectoryTree warnings normally access
	// the in-game message overlay, which does not exist before Init/after Quit.
	// Scope the filter around construction too, and restore it on every exit.
	struct QuietDirectoryInspection {
		LogLevel previous = Output::GetLogLevel();
		QuietDirectoryInspection() { Output::SetLogLevel(LogLevel::Error); }
		~QuietDirectoryInspection() { Output::SetLogLevel(previous); }
	} quiet;
	try {
		// Do not use the global cached root, archive probing, or SetGameFilesystem.
		auto native = std::make_shared<NativeFilesystem>("", FilesystemView());
		auto fs = native->Subtree(path.simplify_path().utf8().get_data());
		if (!fs) return result;
		std::string first, second;
		if (FileFinder::IsRPG2kProject(fs)) {
			first = fs.FindFile(DATABASE_NAME);
			second = fs.FindFile(TREEMAP_NAME);
		} else if (FileFinder::IsEasyRpgProject(fs)) {
			first = fs.FindFile(DATABASE_NAME_EASYRPG);
			second = fs.FindFile(TREEMAP_NAME_EASYRPG);
		} else {
			auto renamed = FileExtGuesser::GetRPG2kProjectWithRenames(fs);
			if (renamed.Empty()) return result;
			first = fs.FindFile(renamed.rpgRTs.first.fname);
			second = fs.FindFile(renamed.rpgRTs.second.fname);
		}
		if (!fs.OpenInputStream(first) || !fs.OpenInputStream(second)) {
			result["error"] = String::utf8("无法读取游戏文件，请检查访问权限。");
			return result;
		}
		result["ok"] = true;
		result["error"] = "";
		const auto ini = fs.FindFile("RPG_RT.ini");
		result["ini_path"] = ini.empty() ? String() : path.path_join(String::utf8(ini.c_str()));
	} catch (const std::exception&) {
		result["error"] = String::utf8("无法读取游戏目录，请重新选择并检查访问权限。");
	}
	return result;
}

void RPGMakerPlayer::start_game() {
	if (engine_running_) {
		UtilityFunctions::push_warning("RPGMakerPlayer: start_game() called while already running.");
		return;
	}
	mp_clear_server_variables();
	if (game_path_.is_empty()) {
		UtilityFunctions::push_error("RPGMakerPlayer: game_path is not set.");
		return;
	}

	try {
		String abs_path = ProjectSettings::get_singleton()->globalize_path(game_path_);
		std::string path_str = abs_path.utf8().get_data();
		UtilityFunctions::print("RPGMakerPlayer: starting game at: ", abs_path);

		std::vector<std::string> args = { "easyrpg-player" };
#if defined(__ANDROID__)
		// Android has no default desktop config directory in Game_Config.
		const String config_path = ProjectSettings::get_singleton()->globalize_path(
			"user://easyrpg-config");
		const Error config_error = DirAccess::make_dir_recursive_absolute(config_path);
		if (config_error != OK && config_error != ERR_ALREADY_EXISTS) {
			throw std::runtime_error("Cannot create Android EasyRPG config directory");
		}
		args.push_back("--config-path");
		args.emplace_back(config_path.utf8().get_data());
#endif
		player_initialized_ = true;
		Player::Init(args);

		auto gamefs = FileFinder::Root().Create(FileFinder::MakeCanonical(path_str, 0));
		if (!gamefs) {
			throw std::runtime_error("Cannot create filesystem for path: " + path_str);
		}
		FileFinder::SetGameFilesystem(gamefs);
		Output::Debug("RPGMakerPlayer: game filesystem set to: {}", path_str);

		FileExtGuesser::RPG2KNonStandardFilenameGuesser rpg2kRemap;
		if (!FileFinder::IsRPG2kProject(FileFinder::Game()) &&
			!FileFinder::IsEasyRpgProject(FileFinder::Game())) {

			rpg2kRemap = FileExtGuesser::GetRPG2kProjectWithRenames(FileFinder::Game());
			if (rpg2kRemap.Empty()) {
				UtilityFunctions::push_error("RPGMakerPlayer: game_path does not appear to be a valid RPG Maker 2000/2003 project.");
				cleanup_engine();
				return;
			}
		}

		godot_ui_ = dynamic_cast<GodotUi*>(DisplayUi.get());
		if (!godot_ui_) {
			UtilityFunctions::push_error(
				"RPGMakerPlayer: DisplayUi is not a GodotUi instance. "
				"Make sure PLAYER_TARGET_PLATFORM=godot is set at compile time.");
			cleanup_engine();
			return;
		}

#if SUPPORT_AUDIO
		godot_ui_->SetNativeMidiMuted(native_midi_muted_);
#endif
		godot_ui_->SetFrameCallback(
			[this](const uint8_t* pixels, int w, int h, int pitch) {
				on_frame_ready(pixels, w, h, pitch);
			}
		);
		godot_ui_->SetVideoSettingsCallback(
			[this](ConfigEnum::ScalingMode mode, bool stretch, int screen_scale) {
				emit_signal(
					"video_settings_changed",
					static_cast<int>(mode),
					stretch,
					screen_scale
				);
			}
		);

		::Font::SetNameTextFallbackData(
			load_font_resource_bytes("res://resources/fonts/creep2.ttf"), false);
		::Font::SetNameTextFallbackData(
			load_font_resource_bytes("res://resources/fonts/3x9PixelFont.ttf"), true);
		Player::CreateGameObjects();
		Instrumentation::Init("EasyRPG-Player");
		Scene::PushTitleScene(false);
		Player::reset_flag = false;

		auto& cbs = GMI().mp_callbacks;

		cbs.on_moved = [this](int x, int y) {
			emit_signal("player_moved", x, y);
		};
		cbs.on_facing = [this](int dir) {
			emit_signal("player_facing_changed", dir);
		};
		cbs.on_speed = [this](int spd) {
			emit_signal("player_speed_changed", spd);
		};
		cbs.on_sprite = [this](const std::string& name, int idx) {
			emit_signal("player_sprite_changed", String(name.c_str()), idx);
		};
		cbs.on_jumped = [this](int x, int y) {
			emit_signal("player_jumped", x, y);
		};
		cbs.on_flash = [this](int r, int g, int b, int p, int f) {
			emit_signal("player_flashed", r, g, b, p, f);
		};
		cbs.on_transparency = [this](int t) {
			emit_signal("player_transparency_changed", t);
		};
		cbs.on_hidden = [this](bool hidden) {
			emit_signal("player_hidden_changed", hidden);
		};
		cbs.on_teleported = [this](int map_id, int x, int y) {
			emit_signal("player_teleported", map_id, x, y);
		};
		cbs.on_se = [this](const std::string& n, int vol, int tempo, int bal) {
			emit_signal("player_se_played", String(n.c_str()), vol, tempo, bal);
		};
		cbs.on_system = [this](const std::string& sys) {
			emit_signal("player_system_changed", String(sys.c_str()));
		};
		cbs.on_map_changed = [this](int map_id) {
			emit_signal("map_changed", map_id);
		};
		cbs.on_switch_set = [this](int sw_id, int val) {
			emit_signal("switch_set", sw_id, val);
		};
		cbs.on_variable_set = [this](int var_id, int val) {
			emit_signal("variable_set", var_id, val);
		};
		cbs.on_event_triggered = [this](int ev_id, bool action) {
			emit_signal("event_triggered", ev_id, action);
		};

		frame_dirty_ = true;
		engine_running_ = true;
		UtilityFunctions::print("RPGMakerPlayer: engine started successfully.");

	} catch (const std::exception& e) {
		UtilityFunctions::push_error(
			String("RPGMakerPlayer: engine error: ") + String(e.what()));
		cleanup_engine();
	} catch (...) {
		UtilityFunctions::push_error("RPGMakerPlayer: unknown engine error during start_game().");
		cleanup_engine();
	}
}

void RPGMakerPlayer::stop_game() {
	cleanup_engine();
}

void RPGMakerPlayer::cleanup_engine() {
	mp_clear_server_variables();
	if (!engine_running_ && !player_initialized_) return;
	engine_running_ = false;
	if (godot_ui_) {
		godot_ui_->SetFrameCallback({});
		godot_ui_->SetVideoSettingsCallback({});
	}
	godot_ui_ = nullptr;
	if (!player_initialized_) return;
	player_initialized_ = false;
	try {
		Player::Exit();
	} catch (const std::exception& e) {
		UtilityFunctions::push_error(
			String("RPGMakerPlayer: engine cleanup error: ") + String(e.what()));
		DisplayUi.reset();
	} catch (...) {
		UtilityFunctions::push_error("RPGMakerPlayer: unknown engine cleanup error.");
		DisplayUi.reset();
	}
}

Ref<ImageTexture> RPGMakerPlayer::get_frame_texture() const { return frame_texture_; }
bool RPGMakerPlayer::is_running() const { return engine_running_; }

PackedFloat32Array RPGMakerPlayer::audio_pull_frames(int frame_count) {
	PerformanceScope audio_scope(performance_enabled_, performance_counters_.data() + 8);
	PackedFloat32Array result;
#if SUPPORT_AUDIO
	if (!godot_ui_ || frame_count <= 0) return result;

	PerformanceScope decode_scope(performance_enabled_, performance_counters_.data() + 10);
	auto s16 = godot_ui_->PullAudioFrames(frame_count);
	decode_scope.finish();
	const int total = static_cast<int>(s16.size());
	result.resize(total);
	float* dst = result.ptrw();
	constexpr float inv = 1.0f / 32768.0f;
	for (int i = 0; i < total; ++i) {
		dst[i] = static_cast<float>(s16[i]) * inv;
	}
#endif
	return result;
}

void RPGMakerPlayer::set_native_midi_muted(bool muted) {
	native_midi_muted_ = muted;
#if SUPPORT_AUDIO
	if (godot_ui_) godot_ui_->SetNativeMidiMuted(muted);
#endif
}

bool RPGMakerPlayer::is_native_midi_muted() const { return native_midi_muted_; }

int RPGMakerPlayer::get_audio_sample_rate() const {
#if SUPPORT_AUDIO
	if (godot_ui_) return godot_ui_->GetAudioSampleRate();
#endif
	return 44100;
}

int RPGMakerPlayer::audio_fill_playback(const Ref<AudioStreamGeneratorPlayback>& playback) {
#if SUPPORT_AUDIO
	if (!engine_running_ || !godot_ui_ || playback.is_null() || !playback->is_playing()) return 0;
	const int available = playback->get_frames_available();
	if (available <= 0) return 0;
	PerformanceScope feed_scope(performance_enabled_, performance_counters_.data() + 21);
	// Allocate the exact submission length before advancing the decoder.
	if (audio_frames_.resize(available) != OK) return -1;
	PerformanceScope decode_scope(performance_enabled_, performance_counters_.data() + 10);
	godot_ui_->PullAudioFrames(available, audio_pcm_);
	decode_scope.finish();
	if (audio_pcm_.size() != static_cast<size_t>(available) * 2) return -1;
	PerformanceScope convert_scope(performance_enabled_, performance_counters_.data() + 17);
	Vector2* dst = audio_frames_.ptrw();
	constexpr float inv = 1.0f / 32768.0f;
	for (int i = 0; i < available; ++i) {
		dst[i] = Vector2(static_cast<float>(audio_pcm_[i * 2]) * inv,
			static_cast<float>(audio_pcm_[i * 2 + 1]) * inv);
	}
	convert_scope.finish();
	// The mixer lock has been released. Consumption only increases free space;
	// with AudioOutput as the sole producer, one whole-block push is sufficient.
	PerformanceScope push_scope(performance_enabled_, performance_counters_.data() + 19);
	return playback->push_buffer(audio_frames_) ? available : -1;
#else
	return 0;
#endif
}

bool RPGMakerPlayer::is_map_ready() const {
	if (!engine_running_ || !Main_Data::game_player) return false;
	if (Scene::Find(Scene::SceneType::Map) == nullptr) return false;
	return true;
}

int RPGMakerPlayer::get_current_map_id() const {
	if (!engine_running_ || !Main_Data::game_player) return 0;
	if (Scene::Find(Scene::SceneType::Map) == nullptr) return 0;
	return Main_Data::game_player->GetMapId();
}

String RPGMakerPlayer::get_original_game_title() const {
	const std::string& title = Player::game_title_original.empty()
		? Player::game_title
		: Player::game_title_original;
	return String::utf8(title.c_str());
}

String RPGMakerPlayer::get_current_language_code() const {
	const auto& current = Player::translation.GetCurrentLanguage();
	if (!current.lang_code.empty()) {
		return String::utf8(current.lang_code.c_str());
	}
	if (!current.lang_dir.empty()) {
		return String::utf8(current.lang_dir.c_str());
	}
	if (!current.lang_name.empty()) {
		return String::utf8(current.lang_name.c_str());
	}

	const auto& fallback = Player::translation.GetDefaultLanguage();
	if (!fallback.lang_code.empty()) {
		return String::utf8(fallback.lang_code.c_str());
	}
	if (!fallback.lang_name.empty()) {
		return String::utf8(fallback.lang_name.c_str());
	}
	return "en";
}

int RPGMakerPlayer::get_current_player_x() const {
	if (!engine_running_ || !Main_Data::game_player) return -1;
	if (Scene::Find(Scene::SceneType::Map) == nullptr) return -1;
	return Main_Data::game_player->GetX();
}

int RPGMakerPlayer::get_current_player_y() const {
	if (!engine_running_ || !Main_Data::game_player) return -1;
	if (Scene::Find(Scene::SceneType::Map) == nullptr) return -1;
	return Main_Data::game_player->GetY();
}

Ref<ImageTexture> RPGMakerPlayer::get_current_system_texture() const {
	if (!engine_running_ || !Main_Data::game_system) return Ref<ImageTexture>();
	// Cache::System() substitutes a dummy bitmap for missing or invalid images.
	// Reject that cached fallback so the banner can atomically use the launcher's
	// border and font instead of mixing both styles.
	if (!Cache::IsSystemGraphicValid()) return Ref<ImageTexture>();
	return bitmap_to_godot_texture(Cache::System());
}

Ref<ImageTexture> RPGMakerPlayer::get_system_texture(const String& system_name) const {
	if (!engine_running_ || !Main_Data::game_system) return Ref<ImageTexture>();
	if (system_name.is_empty()) return get_current_system_texture();
	const CharString utf8 = system_name.utf8();
	const std::string requested(utf8.get_data(), utf8.length());
	const std::string path = FileFinder::FindImage("System", requested);
	if (path.empty()) return Ref<ImageTexture>();
	return bitmap_to_godot_texture(Cache::System(requested));
}

int RPGMakerPlayer::get_current_system_stretch() const {
	if (!engine_running_ || !Main_Data::game_system) return 1;
	return Main_Data::game_system->GetMessageStretch()
		== lcf::rpg::System::Stretch_stretch ? 1 : 0;
}

Ref<ImageTexture> RPGMakerPlayer::render_game_window_with_system(
		const String& system_name, int width, int height, int stretch_mode) const {
	if (!engine_running_ || !Main_Data::game_system || width < 16 || height < 16
			|| width > 2048 || height > 2048) {
		return Ref<ImageTexture>();
	}
	BitmapRef windowskin;
	if (system_name.is_empty()) {
		windowskin = Cache::System();
	} else {
		const CharString utf8 = system_name.utf8();
		const std::string requested(utf8.get_data(), utf8.length());
		const std::string path = FileFinder::FindImage("System", requested);
		if (path.empty()) return Ref<ImageTexture>();
		windowskin = Cache::System(requested);
	}
	if (!windowskin) return Ref<ImageTexture>();
	BitmapRef rendered = Bitmap::Create(width, height, true);
	if (!rendered || !rendered->pixels()) return Ref<ImageTexture>();
	if (stretch_mode != 0) {
		rendered->StretchBlit(*windowskin, Rect(0, 0, 32, 32), 255);
	} else {
		rendered->TiledBlit(Rect(0, 0, 32, 32), *windowskin, rendered->GetRect(), 255);
	}
	const int inner_width = std::max(width - 16, 1);
	const int inner_height = std::max(height - 16, 1);
	rendered->TiledBlit(8, 0, Rect(40, 0, 16, 8), *windowskin,
		Rect(8, 0, inner_width, 8), 255);
	rendered->TiledBlit(8, height - 8, Rect(40, 24, 16, 8), *windowskin,
		Rect(8, height - 8, inner_width, 8), 255);
	if (height > 16) {
		rendered->TiledBlit(0, 8, Rect(32, 8, 8, 16), *windowskin,
			Rect(0, 8, 8, inner_height), 255);
		rendered->TiledBlit(width - 8, 8, Rect(56, 8, 8, 16), *windowskin,
			Rect(width - 8, 8, 8, inner_height), 255);
	}
	rendered->Blit(0, 0, *windowskin, Rect(32, 0, 8, 8), 255);
	rendered->Blit(width - 8, 0, *windowskin, Rect(56, 0, 8, 8), 255);
	rendered->Blit(0, height - 8, *windowskin, Rect(32, 24, 8, 8), 255);
	rendered->Blit(width - 8, height - 8, *windowskin, Rect(56, 24, 8, 8), 255);
	return bitmap_to_godot_texture(rendered);
}

Ref<ImageTexture> RPGMakerPlayer::render_character_avatar(
		const String& sprite_name, int sprite_index, int facing) const {
	if (!engine_running_ || sprite_name.is_empty() || sprite_index < 0 || sprite_index > 7) {
		return Ref<ImageTexture>();
	}
	const CharString utf8 = sprite_name.utf8();
	const std::string requested(utf8.get_data(), utf8.length());
	const std::string path = FileFinder::FindImage("CharSet", requested);
	if (path.empty()) return Ref<ImageTexture>();
	const BitmapRef charset = Cache::Charset(requested);
	if (!charset) return Ref<ImageTexture>();
	const Rect character = Sprite_Character::GetCharacterRect(
		requested, sprite_index, charset->GetRect());
	const int frame_width = character.width / 3;
	const int frame_height = character.height / 4;
	if (frame_width <= 0 || frame_height <= 0) return Ref<ImageTexture>();
	const Rect source(character.x + frame_width,
		character.y + std::clamp(facing, 0, 3) * frame_height,
		frame_width, frame_height);
	BitmapRef rendered = Bitmap::Create(frame_width, frame_height, true);
	if (!rendered || !rendered->pixels()) return Ref<ImageTexture>();
	rendered->Clear();
	rendered->Blit(0, 0, *charset, source, 255);
	return bitmap_to_godot_texture(rendered);
}

Ref<ImageTexture> RPGMakerPlayer::render_character_profile(
		const String& sprite_name, int sprite_index) const {
	if (!engine_running_ || sprite_name.is_empty() || sprite_index < 0 || sprite_index > 7) {
		return Ref<ImageTexture>();
	}
	const CharString utf8 = sprite_name.utf8();
	const std::string requested(utf8.get_data(), utf8.length());
	const std::string path = FileFinder::FindImage("CharSet", requested);
	if (path.empty()) return Ref<ImageTexture>();
	const BitmapRef charset = Cache::Charset(requested);
	if (!charset) return Ref<ImageTexture>();
	const Rect character = Sprite_Character::GetCharacterRect(
		requested, sprite_index, charset->GetRect());
	const int frame_width = character.width / 3;
	const int frame_height = character.height / 4;
	if (frame_width <= 0 || frame_height <= 0) return Ref<ImageTexture>();

	// YNO player-list profiles always use the front-facing middle frame. The
	// canonical 24x32 frame is cropped to 20x16, with the crop following the
	// first opaque row so hats and short sprites remain framed consistently.
	const Rect source(character.x + frame_width,
		character.y + 2 * frame_height, frame_width, frame_height);
	BitmapRef frame = Bitmap::Create(frame_width, frame_height, true);
	if (!frame || !frame->pixels()) return Ref<ImageTexture>();
	frame->Clear();
	frame->Blit(0, 0, *charset, source, 255);

	int first_opaque_row = -1;
	const auto* pixels = static_cast<const uint8_t*>(frame->pixels());
	for (int y = 0; y < frame_height && first_opaque_row < 0; ++y) {
		const uint8_t* row = pixels + y * frame->pitch();
		for (int x = 0; x < frame_width; ++x) {
			if (row[x * 4 + 3] != 0) {
				first_opaque_row = y;
				break;
			}
		}
	}

	auto proportional = [](int value, int extent, int canonical) -> int {
		return std::max(1, (value * extent + canonical / 2) / canonical);
	};
	const int crop_x = std::min(proportional(2, frame_width, 24), frame_width - 1);
	const int crop_width = std::min(
		proportional(20, frame_width, 24), frame_width - crop_x);
	const int crop_height = std::min(
		proportional(16, frame_height, 32), frame_height);
	int crop_y = 0;
	if (first_opaque_row >= 0) {
		const int minimum_y = std::min(
			proportional(3, frame_height, 32), frame_height - 1);
		const int maximum_y = std::max(minimum_y, std::min(
			proportional(15, frame_height, 32), frame_height - 1));
		crop_y = std::clamp(first_opaque_row, minimum_y, maximum_y);
	}
	crop_y = std::min(crop_y, frame_height - crop_height);

	BitmapRef rendered = Bitmap::Create(20, 16, true);
	if (!rendered || !rendered->pixels()) return Ref<ImageTexture>();
	rendered->Clear();
	rendered->StretchBlit(
		*frame, Rect(crop_x, crop_y, crop_width, crop_height), 255);
	return bitmap_to_godot_texture(rendered);
}

Dictionary RPGMakerPlayer::render_current_game_text(const String& text, int max_width) const {
	Dictionary result;
	if (!engine_running_ || !Main_Data::game_system || text.is_empty() || max_width <= 0) {
		return result;
	}

	const BitmapRef system = Cache::System();
	const FontRef font = ::Font::Default();
	if (!system || !font) return result;

	return render_text_bitmap(text, max_width, system, font, ::Font::ColorDefault);
}

Dictionary RPGMakerPlayer::render_game_text_with_system(
		const String& text, const String& system_name, int max_width, int color_index) const {
	Dictionary result;
	if (!engine_running_ || !Main_Data::game_system || text.is_empty()
			|| system_name.is_empty() || max_width <= 0) {
		return result;
	}

	const CharString system_utf8 = system_name.utf8();
	const std::string requested_system(system_utf8.get_data(), system_utf8.length());
	const std::string system_path = FileFinder::FindImage("System", requested_system);
	if (system_path.empty()) return result;

	const BitmapRef system = Cache::System(requested_system);
	const FontRef font = ::Font::Default();
	if (!system || !font) return result;

	return render_text_bitmap(text, max_width, system, font, std::clamp(color_index, 0, 19));
}

void RPGMakerPlayer::mp_set_session_active(bool active) {
	if (!engine_running_) return;
	GMI().session_active = active;
}

void RPGMakerPlayer::mp_notify_room_ready() {
	if (!engine_running_) return;
	GMI().switching_room = false;
}

bool RPGMakerPlayer::mp_apply_server_variables(const Dictionary& values) {
	if (!engine_running_ || !Main_Data::game_variables || !Player::IsCollectiveUnconscious()) {
		return false;
	}
	if (values.is_empty() || values.size() > 7) {
		return false;
	}

	std::vector<std::pair<int, int>> updates;
	updates.reserve(values.size());
	const Array keys = values.keys();
	for (int i = 0; i < keys.size(); ++i) {
		const Variant key = keys[i];
		if (key.get_type() != Variant::INT) {
			return false;
		}
		const int64_t variable_id_64 = static_cast<int64_t>(key);
		if (variable_id_64 < 1231 || variable_id_64 > 1237) {
			return false;
		}
		const Variant raw_value = values[key];
		if (raw_value.get_type() != Variant::INT) {
			return false;
		}
		const int64_t value_64 = static_cast<int64_t>(raw_value);
		bool valid = false;
		switch (variable_id_64) {
			case 1231: valid = value_64 >= 0 && value_64 <= 255; break;
			case 1232: valid = value_64 >= 0 && value_64 <= std::numeric_limits<int32_t>::max(); break;
			case 1233: valid = value_64 >= 0 && value_64 <= 19; break;
			case 1234: valid = value_64 >= 0 && value_64 <= 11; break;
			case 1235: valid = value_64 >= -100 && value_64 <= 100; break;
			case 1236: valid = value_64 >= 0 && value_64 <= 100; break;
			case 1237: valid = value_64 >= 0 && value_64 <= 7; break;
		}
		const int variable_id = static_cast<int>(variable_id_64);
		if (!valid || !Main_Data::game_variables->IsValid(variable_id)) {
			return false;
		}
		updates.emplace_back(variable_id, static_cast<int>(value_64));
	}

	// Keep the embedded legacy CU updater coherent so it cannot overwrite the
	// freshly applied values on the following engine frame.
	for (const auto& [variable_id, value] : updates) {
		switch (variable_id) {
			case 1231: GMI().cu_randint = value; break;
			case 1233: GMI().cu_time_hours = value; break;
			case 1234: GMI().cu_time_days = value; break;
			case 1235: GMI().cu_temperature = value; break;
			case 1236: GMI().cu_precipitation = value; break;
			default: break;
		}
	}

	for (const auto& [variable_id, value] : updates) {
		server_variables_[variable_id] = value;
		Main_Data::game_variables->Set(variable_id, value);
	}
	server_variables_active_ = true;
	GMI().server_global_variables_active = true;
	for (const auto& [variable_id, _value] : updates) {
		Game_Map::SetNeedRefreshForVarChange(variable_id);
	}
	return true;
}

void RPGMakerPlayer::mp_clear_server_variables() {
	server_variables_active_ = false;
	server_variables_.clear();
	if (engine_running_) {
		GMI().server_global_variables_active = false;
	}
}

void RPGMakerPlayer::enforce_server_variables() {
	if (!server_variables_active_ || !engine_running_ || !Main_Data::game_variables ||
			!Player::IsCollectiveUnconscious()) {
		return;
	}

	for (const auto& [variable_id, value] : server_variables_) {
		if (!Main_Data::game_variables->IsValid(variable_id) ||
				Main_Data::game_variables->Get(variable_id) == value) {
			continue;
		}
		Main_Data::game_variables->Set(variable_id, value);
		Game_Map::SetNeedRefreshForVarChange(variable_id);
	}
}

void RPGMakerPlayer::inject_key(int easyrpg_key_id, bool pressed) {
	if (godot_ui_)
		godot_ui_->SetKeyState(easyrpg_key_id, pressed);
}

void RPGMakerPlayer::open_save_menu() {
	if (!engine_running_ || !Scene::instance) return;
	Scene::instance->SetRequestedScene(std::make_shared<Scene_Save>());
}

void RPGMakerPlayer::open_load_menu() {
	if (!engine_running_ || !Scene::instance) return;
	Scene::instance->SetRequestedScene(std::make_shared<Scene_Load>());
}

void RPGMakerPlayer::open_debug_menu() {
	if (!engine_running_ || !Scene::instance) return;
	Scene::instance->SetRequestedScene(std::make_shared<Scene_Debug>());
}

bool RPGMakerPlayer::set_resolution(int width, int height) {
	if (!engine_running_) {
		UtilityFunctions::push_warning(
			"RPGMakerPlayer: set_resolution() called while engine is not running.");
		return false;
	}
	if (width <= 0 || height <= 0) {
		UtilityFunctions::push_error(
			"RPGMakerPlayer: set_resolution() called with invalid dimensions.");
		return false;
	}
	bool ok = Player::ChangeResolution(width, height);
	if (!ok) {
		UtilityFunctions::push_warning(
			String("RPGMakerPlayer: resolution change to ") +
			String::num_int64(width) + "x" + String::num_int64(height) + " failed.");
	}
	return ok;
}

int RPGMakerPlayer::get_screen_width() const {
	return Player::screen_width;
}

int RPGMakerPlayer::get_screen_height() const {
	return Player::screen_height;
}

void RPGMakerPlayer::mp_add_player(int id, int x, int y,
                                   const String& sprite_name, int sprite_index,
                                   int facing, int speed) {
	if (!engine_running_) return;
	GMI().GodotMpAddPlayer(id, x, y, sprite_name.utf8().get_data(), sprite_index, facing, speed);
}

void RPGMakerPlayer::mp_remove_player(int id) {
	if (!engine_running_) return;
	GMI().GodotMpRemovePlayer(id);
}

void RPGMakerPlayer::mp_clear_remote_players_immediate() {
	if (!engine_running_) return;
	GMI().ClearRemotePlayersImmediate();
	frame_dirty_ = true;
}

void RPGMakerPlayer::mp_clear_remote_player_objects_immediate() {
	if (!engine_running_) return;
	GMI().ClearRemotePlayerObjectsImmediate();
	frame_dirty_ = true;
}

void RPGMakerPlayer::mp_move_player(int id, int x, int y) {
	if (!engine_running_) return;
	GMI().GodotMpMovePlayer(id, x, y);
}

void RPGMakerPlayer::mp_jump_player(int id, int x, int y) {
	if (!engine_running_) return;
	GMI().GodotMpJumpPlayer(id, x, y);
}

void RPGMakerPlayer::mp_set_player_facing(int id, int facing) {
	if (!engine_running_) return;
	GMI().GodotMpSetFacing(id, facing);
}

void RPGMakerPlayer::mp_set_player_speed(int id, int speed) {
	if (!engine_running_) return;
	GMI().GodotMpSetSpeed(id, speed);
}

void RPGMakerPlayer::mp_set_player_sprite(int id, const String& name, int index) {
	if (!engine_running_) return;
	GMI().GodotMpSetSprite(id, name.utf8().get_data(), index);
}

void RPGMakerPlayer::mp_set_player_transparency(int id, int transparency) {
	if (!engine_running_) return;
	GMI().GodotMpSetTransparency(id, transparency);
}

void RPGMakerPlayer::mp_set_player_hidden(int id, bool hidden) {
	if (!engine_running_) return;
	GMI().GodotMpSetHidden(id, hidden);
	frame_dirty_ = true;
}

void RPGMakerPlayer::mp_flash_player(int id, int r, int g, int b, int power, int frames) {
	if (!engine_running_) return;
	GMI().GodotMpFlash(id, r, g, b, power, frames);
}

void RPGMakerPlayer::mp_sync_local_player() {
	if (!engine_running_) return;
	GMI().GodotFireLocalPlayerCallbacks();
}

void RPGMakerPlayer::mp_set_room(int room_id) {
	if (!engine_running_) return;
	GMI().Connect(room_id, true);
}

void RPGMakerPlayer::mp_set_room_id(int room_id) {
	if (!engine_running_) return;
	GMI().room_id = room_id;
}

void RPGMakerPlayer::mp_play_se(const String& name, int volume, int tempo, int balance) {
	if (!engine_running_) return;
	GMI().GodotMpPlaySe(name.utf8().get_data(), volume, tempo, balance);
}

void RPGMakerPlayer::mp_set_player_name(int id, const String& name) {
	if (!engine_running_) return;
	GMI().GodotMpSetPlayerName(id, name.utf8().get_data());
}

void RPGMakerPlayer::mp_set_player_system_graphic(int id, const String& sys_name) {
	if (!engine_running_) return;
	GMI().GodotMpSetPlayerSystemGraphic(id, sys_name.utf8().get_data());
}

void RPGMakerPlayer::mp_set_nametag_mode(int mode) {
	if (!engine_running_) return;
	GMI().SetNametagMode(mode);
	frame_dirty_ = true;
}

Ref<ImageTexture> RPGMakerPlayer::mp_render_nametag_mode_preview(int mode) const {
	if (!engine_running_ || mode < 0 || mode > 3) {
		return Ref<ImageTexture>();
	}

	const FontRef font = ::Font::NameTextForMode(mode);
	if (!font) {
		return Ref<ImageTexture>();
	}

	const std::string preview_text = mode <= 1
		? "ABC"
		: (mode == 2 ? "Abcde" : "Abcdefg");
	auto style = font->GetCurrentStyle();
	style.draw_shadow = false;
	style.draw_gradient = false;
	style.color_offset = Point(0, 0);
	auto style_guard = font->ApplyStyle(style);
	const Rect measured = Text::GetSize(*font, preview_text);
	const int source_width = std::max(1, measured.width + 2);
	const int source_height = std::max(1, measured.height + 2);
	BitmapRef source = Bitmap::Create(source_width, source_height, true);
	BitmapRef white_system = Bitmap::Create(160, 80, ::Color(255, 255, 255, 255));
	if (!source || !source->pixels() || !white_system) {
		return Ref<ImageTexture>();
	}
	source->Clear();
	Text::Draw(
		*source, 1, 1, *font, *white_system, ::Font::ColorDefault,
		preview_text, Text::AlignLeft);

	if (mode == 0) {
		const int line_width = std::max(1, source_width - 2);
		const int line_y = std::clamp(
			1 + (std::max(1, measured.height) - 1) / 2,
			1,
			std::max(1, source_height - 2));
		source->ClearRect(Rect(0, line_y - 1, source_width, 3));
		source->FillRect(Rect(1, line_y, line_width, 1),
			::Color(255, 255, 255, 255));
	}
	return bitmap_to_godot_texture(source);
}

void RPGMakerPlayer::on_frame_ready(const uint8_t* pixels, int width, int height, int pitch) {
	if (!pixels || width <= 0 || height <= 0) return;
	PerformanceScope convert_scope(performance_enabled_, performance_counters_.data() + 4);

	if (performance_enabled_) ++performance_counters_[16];
	const bool size_changed = frame_image_.is_null() ||
		frame_image_->get_width()  != width ||
		frame_image_->get_height() != height;

	if (size_changed) {
		frame_image_ = Image::create(width, height, false, Image::FORMAT_RGBA8);
	}

	// ynoengine ARGB8888 (LE: B G R A)
	// Godot RGBA8888 (R G B A)
	PackedByteArray data;
	data.resize(width * height * 4);
	uint8_t* dst = data.ptrw();

	for (int y = 0; y < height; ++y) {
		const uint8_t* src_row = pixels + y * pitch;
		uint8_t* dst_row = dst + y * width * 4;
		for (int x = 0; x < width; ++x) {
			uint8_t b = src_row[x * 4 + 0];
			uint8_t g = src_row[x * 4 + 1];
			uint8_t r = src_row[x * 4 + 2];
			dst_row[x * 4 + 0] = r;
			dst_row[x * 4 + 1] = g;
			dst_row[x * 4 + 2] = b;
			dst_row[x * 4 + 3] = 255;
		}
	}

	convert_scope.finish();
	PerformanceScope upload_scope(performance_enabled_, performance_counters_.data() + 6);
	frame_image_->set_data(width, height, false, Image::FORMAT_RGBA8, data);

	if (frame_texture_.is_null() || size_changed) {
		frame_texture_ = ImageTexture::create_from_image(frame_image_);
		emit_signal("resolution_changed", width, height);
	} else {
		frame_texture_->update(frame_image_);
	}
}

} // namespace godot
