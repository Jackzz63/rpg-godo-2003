#include "chatname.h"
#include "../cache.h"
#include "../font.h"
#include "../drawable_mgr.h"
#include "../filefinder.h"
#include "../bitmap.h"
#include "../sprite_character.h"
#include "../game_playerother.h"
#include "playerother.h"

namespace {
	constexpr int BASE_OFFSET = -13;
	constexpr size_t FRAMES_PER_CHARACTER = 12;
	constexpr size_t SPRITE_Y_OFFSET_COUNT = 96;
	static_assert(SPRITE_Y_OFFSET_COUNT % FRAMES_PER_CHARACTER == 0);

	constexpr bool CanScanSpriteYOffsetLayout(int rows, int columns) {
		if (rows <= 0 || columns <= 0) {
			return true;
		}

		// The cache index reserves four character columns per row.
		const size_t last_cell = static_cast<size_t>(rows - 1) * 4
			+ static_cast<size_t>(columns - 1);
		return last_cell < SPRITE_Y_OFFSET_COUNT / FRAMES_PER_CHARACTER;
	}

	static_assert(CanScanSpriteYOffsetLayout(2, 4));
	static_assert(CanScanSpriteYOffsetLayout(1, 8));
	static_assert(CanScanSpriteYOffsetLayout(0, 100));
	static_assert(!CanScanSpriteYOffsetLayout(2, 5));
	static_assert(!CanScanSpriteYOffsetLayout(1, 9));
	static_assert(!CanScanSpriteYOffsetLayout(3, 1));
}

std::map<std::string, std::array<int, SPRITE_Y_OFFSET_COUNT>> sprite_y_offsets;

ChatName::ChatName(int id, PlayerOther& player, std::string nickname)
	:player(player),
	nickname(std::move(nickname)),
	// names are drawn below picture overlays (Priority_Picture*) and screen flashes (Priority_Screen)
	Drawable(Priority_Weather + id + 1) {
	DrawableMgr::Register(this);
}

void ChatName::Draw(Bitmap& dst) {
	auto nametag_mode = GMI().GetNametagMode();
	
	if (nametag_mode == Game_Multiplayer::NametagMode::NONE || nickname.empty() || !player.sprite.get()) {
		nick_img.reset();
		dirty = true;
		return;
	}

	if (nametag_mode_cache != nametag_mode) {
		nametag_mode_cache = nametag_mode;
		nick_img.reset();
		dirty = true;
	}

	if (dirty) {
		std::string nick_trim;

		if (nametag_mode != Game_Multiplayer::NametagMode::CLASSIC) {
			nick_trim = player.account ? nickname : "<" + nickname + ">";
		} else {
			nick_trim = nickname.substr(0, std::min(3, (int)nickname.size()));
		}

		// FIXME: Text::GetSize is broken and always returns a height of 0, use 12 for now
		auto rect = Text::GetSize(*Font::NameText(), nick_trim);
		nick_img = Bitmap::Create(rect.width, 12);
		nick_img->SetId(fmt::format("nametag:{}", nickname));

		Text::Draw(*nick_img, 0, 0, *Font::NameText(), *(sys_graphic ? sys_graphic : Cache::SystemOrBlack()), 0, nick_trim);

		dirty = false;

		effects_dirty = true;
	}

	if (flash_frames_left > 0) {
		--flash_frames_left;
		effects_dirty = true;
	}

	if (effects_dirty) {
		auto tone = player.sprite->GetTone();
		auto flash = player.sprite->GetCharacter()->GetFlashColor();

		effects_img.reset(); // maybe not needed?

		if (tone == Tone() && flash.alpha == 0) {
			effects_img = nick_img;
		} else {
			effects_img = Cache::SpriteEffect(nick_img, nick_img->GetRect(), false, false, tone, flash);
		}

		effects_dirty = false;
	}

	if (!player.ch->IsSpriteHidden()) {
		int x = player.ch->GetScreenX() - nick_img->GetWidth() / 2;
		int y = (player.ch->GetScreenY() - player.sprite->GetHeight()) + GetSpriteYOffset();

		if (transparent && base_opacity > 16) {
			SetBaseOpacity(base_opacity - 1);
		} else if (!transparent && base_opacity < 32) {
			SetBaseOpacity(base_opacity + 1);
		}

		dst.Blit(x, y, *effects_img, effects_img->GetRect(), Opacity(GetOpacity()));
	}
}

void ChatName::SetSystemGraphic(std::string_view sys_name) {
	FileRequestAsync* request = AsyncHandler::RequestFile("System", sys_name);
	request_id = request->Bind([this](FileRequestResult* result) {
		if (!result->success) {
			return;
		}
		sys_graphic = Cache::System(result->file);
		dirty = true;
	});
	request->SetGraphicFile(true);
	request->Start();
}

void ChatName::SetTransparent(bool val) {
	transparent = val;
}

int ChatName::GetOpacity() {
	float opacity = (float)player.ch->GetOpacity() * ((float)base_opacity / 32.0);
	return std::floor(opacity);
}

int ChatName::GetSpriteYOffset() {
	std::string sprite_name = player.ch->GetSpriteName();
	auto offsets_it = sprite_y_offsets.find(sprite_name);
	if (offsets_it == sprite_y_offsets.end()) {
		auto filename = FileFinder::FindImage("CharSet", sprite_name);
		if (filename == "") {
			return 0;
		}

		auto offset_array = std::array<int, SPRITE_Y_OFFSET_COUNT>{ 0 };
		const size_t BGRA = 4;

		auto image = Cache::Charset(sprite_name);
		const int rows = image->height() / 128;
		const int columns = image->width() / 72;
		const bool has_cells = rows > 0 && columns > 0;

		if (has_cells && !CanScanSpriteYOffsetLayout(rows, columns)) {
			offset_array.fill(BASE_OFFSET);
		} else if (has_cells) {
			auto pixels = reinterpret_cast<unsigned char*>(image->pixels());
			for (int hi = 0; hi < rows; ++hi) {
				for (int wi = 0; wi < columns; ++wi) {
					for (int fi = 0; fi < 4; ++fi) {
						for (int afi = 0; afi < 3; ++afi) {
							size_t i = (static_cast<size_t>(hi) * 4 + static_cast<size_t>(wi)) * FRAMES_PER_CHARACTER
								+ static_cast<size_t>(fi * 3 + afi);
							if (i >= offset_array.size()) {
								offset_array.fill(BASE_OFFSET);
								sprite_y_offsets.emplace(sprite_name, offset_array);
								return BASE_OFFSET;
							}

							int start_x = wi * 72 + afi * 24;
							int start_y = hi * 128 + fi * 32;

							int y = start_y;

							bool offset_found = false;

							for (; y < start_y + 32; ++y) {
								for (int x = start_x; x < start_x + 24; ++x) {
									size_t index = BGRA * (y * image->width() + x);
									if (pixels[index + 3] != 0) { // check if alpha is not 0 (fully transparent)
										offset_found = true;
										break;
									}
								}

								if (offset_found) {
									break;
								}
							}

							if (offset_found) {
								if (y > start_y + 15) {
									y = start_y + 15;
								}
								offset_array[i] = BASE_OFFSET + (y - start_y);
							} else {
								offset_array[i] = 32;
							}
						}
					}
				}
			}
		}

		offsets_it = sprite_y_offsets.emplace(sprite_name, offset_array).first;
	}

	auto frame = player.ch->GetAnimFrame();
	if (frame >= lcf::rpg::EventPage::Frame_middle2) {
		frame = lcf::rpg::EventPage::Frame_middle;
	}

	const int sprite_index = player.ch->GetSpriteIndex();
	const int facing = player.ch->GetFacing();
	if (sprite_index < 0 || sprite_index >= 8 ||
			facing < 0 || facing >= 4 ||
			frame < 0 || frame >= 3) {
		return last_valid_sprite_y_offset;
	}

	const size_t offset_index = static_cast<size_t>(sprite_index) * FRAMES_PER_CHARACTER
		+ static_cast<size_t>(facing * 3 + frame);
	if (offset_index >= offsets_it->second.size()) {
		return last_valid_sprite_y_offset;
	}

	int ret = offsets_it->second[offset_index];

	if (ret != 32) {
		last_valid_sprite_y_offset = ret;
	} else {
		return last_valid_sprite_y_offset;
	}

	return ret;
}
