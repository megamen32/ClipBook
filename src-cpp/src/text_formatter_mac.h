#ifndef CLIPBOOK_TEXT_FORMATTER_MAC_H_
#define CLIPBOOK_TEXT_FORMATTER_MAC_H_

#include <string>

namespace text_formatter_mac {

enum class TextFormatAction {
  kLowerCase = 0,
  kUpperCase,
  kCapitalizeWords,
  kSentenceCase,
  kRemoveEmptyLines,
  kStripAllWhitespaces,
  kTrimSurroundingWhitespaces,
};

std::string applyTextFormat(const std::string &text, TextFormatAction action);

// Converts the text from the current input source to the next enabled keyboard
// input source by keyboard key positions and switches to that next source.
// Returns the transformed text. If switching failed, the original text is
// returned and did_switch_input_source is set to false.
std::string rotateTextInputSource(const std::string &text,
                                  bool *did_switch_input_source);

// Switches to the next enabled keyboard input source.
bool selectNextInputSource();

} // namespace text_formatter_mac

#endif // CLIPBOOK_TEXT_FORMATTER_MAC_H_
