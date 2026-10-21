#include "ui.h"

#include "bitmap.h"
#include "color.h"
#include "game_config.h"
#include "keys.h"
#include "output.h"
#include "pixel_format.h"

#include <algorithm>

#if SUPPORT_AUDIO
#include "audio.h"
#include "platform/godot/audio.h"
#endif

GodotUi::GodotUi(int width, int height, const Game_Config& cfg)
	: BaseUi(cfg)
{
	current_display_mode.width  = width;
	current_display_mode.height = height;
	current_display_mode.bpp    = 32;
	SetFrameRateSynchronized(true);
	const DynamicFormat format(
		32,
		0x00FF0000, // R
		0x0000FF00, // G
		0x000000FF, // B
		0xFF000000, // A
		PF::NoAlpha
	);
	Bitmap::SetFormat(Bitmap::ChooseFormat(format));
	main_surface = Bitmap::Create(
		current_display_mode.width,
		current_display_mode.height,
		false,
		current_display_mode.bpp
	);

#if SUPPORT_AUDIO
	audio_ = std::make_unique<GodotAudio>(cfg.audio);
#endif
}

bool GodotUi::ProcessEvents() {
	// process implemented inside rpgmaker_player.cpp
	return true;
}

void GodotUi::UpdateDisplay() {
	if (!main_surface) {
		return;
	}

	if (frame_callback_) {
		frame_callback_(
			reinterpret_cast<const uint8_t*>(main_surface->pixels()),
			current_display_mode.width,
			current_display_mode.height,
			main_surface->pitch()
		);
	}
}

void GodotUi::SetScalingMode(ConfigEnum::ScalingMode mode) {
	vcfg.scaling_mode.Set(mode);
	NotifyVideoSettingsChanged();
}

void GodotUi::ToggleStretch() {
	vcfg.stretch.Toggle();
	NotifyVideoSettingsChanged();
}

void GodotUi::SetScreenScale(int scale) {
	vcfg.screen_scale.Set(std::clamp(scale, 50, 150));
	NotifyVideoSettingsChanged();
}

void GodotUi::vGetConfig(Game_ConfigVideo& cfg) const {
	cfg.renderer.Lock("Godot (Software)");
	cfg.scaling_mode.SetOptionVisible(true);
	cfg.stretch.SetOptionVisible(true);
	cfg.game_resolution.SetOptionVisible(true);
	cfg.screen_scale.SetOptionVisible(true);
}

bool GodotUi::vChangeDisplaySurfaceResolution(int new_width, int new_height) {
	BitmapRef new_surface = Bitmap::Create(new_width, new_height, false, current_display_mode.bpp);
	if (!new_surface) {
		Output::Warning("GodotUi: vChangeDisplaySurfaceResolution Bitmap::Create failed ({}x{})",
			new_width, new_height);
		return false;
	}

	main_surface = new_surface;
	current_display_mode.width  = new_width;
	current_display_mode.height = new_height;
	return true;
}

#if SUPPORT_AUDIO
AudioInterface& GodotUi::GetAudio() {
	return *audio_;
}
#endif

const uint8_t* GodotUi::GetFramePixels() const {
	if (!main_surface) return nullptr;
	return reinterpret_cast<const uint8_t*>(main_surface->pixels());
}

int GodotUi::GetFramePitch() const {
	if (!main_surface) return 0;
	return main_surface->pitch();
}

int GodotUi::GetFrameWidth() const {
	return current_display_mode.width;
}

int GodotUi::GetFrameHeight() const {
	return current_display_mode.height;
}

void GodotUi::SetKeyState(int key_id, bool pressed) {
	if (key_id >= 0 && key_id < static_cast<int>(keys.size())) {
		keys[key_id] = pressed;
	}
}

void GodotUi::SetFrameCallback(FrameCallback cb) {
	frame_callback_ = std::move(cb);
}

void GodotUi::SetVideoSettingsCallback(VideoSettingsCallback cb) {
	video_settings_callback_ = std::move(cb);
	NotifyVideoSettingsChanged();
}

void GodotUi::NotifyVideoSettingsChanged() {
	if (video_settings_callback_) {
		video_settings_callback_(
			vcfg.scaling_mode.Get(),
			vcfg.stretch.Get(),
			vcfg.screen_scale.Get()
		);
	}
}

#if SUPPORT_AUDIO
std::vector<int16_t> GodotUi::PullAudioFrames(int frame_count) {
	if (auto* ga = dynamic_cast<GodotAudio*>(audio_.get())) {
		return ga->PullFrames(frame_count);
	}
	return {};
}

int GodotUi::GetAudioSampleRate() const {
	return GodotAudio::SAMPLE_RATE;
}

void GodotUi::SetNativeMidiMuted(bool muted) {
	if (auto* ga = dynamic_cast<GodotAudio*>(audio_.get())) {
		ga->SetNativeMidiMuted(muted);
	}
}

void GodotUi::PullAudioFrames(int frame_count, std::vector<int16_t>& out) {
	if (auto* ga = dynamic_cast<GodotAudio*>(audio_.get())) {
		ga->PullFrames(frame_count, out);
	} else {
		out.clear();
	}
}
#endif
