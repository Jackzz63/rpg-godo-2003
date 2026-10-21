extends RefCounted

const LocationResolver := preload("res://cogs/locations/location_resolver.gd")
# Verbatim messages.playerList.unnamed from forest-orb/lang (70bab709).
# Markers belong to the presentation, never to a player's stored nickname.
const UNNAMED_LABELS := {
	"ar": "لاعب غير مسمى", "de": "Unbenannter Spieler", "en": "Unnamed Player",
	"eo": "Sennoma Ludanto", "es": "Anónimo", "fr": "Joueur Sans Nom",
	"id": "Unnamed Player", "it": "Giocatore Anonimo", "ja": "無名プレイヤー",
	"ko": "익명의 플레이어", "pl": "Gracz bez nazwy", "pt": "Jogador Sem Nome",
	"ro": "Jucător fără Nume", "ru": "Безымянный игрок", "tr": "İsimsiz Oyuncu",
	"uk": "Без ім'я", "vi": "Không tên", "zh": "无名子",
}


static func label(nickname: String, language: String) -> String:
	return nickname if not nickname.is_empty() else str(UNNAMED_LABELS.get(
		LocationResolver.normalize_language_code(language), "Unnamed Player"))


static func display(nickname: String, language: String, chat_prefix: bool = false) -> String:
	if nickname.is_empty():
		return "<%s>" % label(nickname, language)
	return "[%s]" % nickname if chat_prefix else nickname
