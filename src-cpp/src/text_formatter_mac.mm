#include "text_formatter_mac.h"

#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

#include <vector>

namespace text_formatter_mac {

namespace {

bool isSameInputSource(TISInputSourceRef lhs, TISInputSourceRef rhs) {
  if (lhs == nullptr || rhs == nullptr) {
    return false;
  }
  auto lhs_id = static_cast<CFStringRef>(
      TISGetInputSourceProperty(lhs, kTISPropertyInputSourceID));
  auto rhs_id = static_cast<CFStringRef>(
      TISGetInputSourceProperty(rhs, kTISPropertyInputSourceID));
  return lhs_id != nullptr && rhs_id != nullptr && CFEqual(lhs_id, rhs_id);
}

const UCKeyboardLayout *layoutForInputSource(TISInputSourceRef source) {
  if (source == nullptr) {
    return nullptr;
  }
  auto data = static_cast<CFDataRef>(TISGetInputSourceProperty(
      source, kTISPropertyUnicodeKeyLayoutData));
  if (data == nullptr) {
    return nullptr;
  }
  return reinterpret_cast<const UCKeyboardLayout *>(CFDataGetBytePtr(data));
}

NSString *translateKeyCode(const UCKeyboardLayout *layout,
                           UInt16 key_code,
                           UInt32 carbon_modifiers) {
  if (layout == nullptr) {
    return @"";
  }
  UInt32 dead_key_state = 0;
  UniChar chars[8] = {0};
  UniCharCount length = 0;
  UInt32 modifier_key_state = (carbon_modifiers >> 8) & 0xFF;
  OSStatus status = UCKeyTranslate(
      layout, key_code, kUCKeyActionDown, modifier_key_state, LMGetKbdType(),
      kUCKeyTranslateNoDeadKeysBit, &dead_key_state, 8, &length, chars);
  if (status != noErr || length == 0) {
    return @"";
  }
  return [NSString stringWithCharacters:chars length:length];
}

NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *buildKeyMapForLayout(
    const UCKeyboardLayout *layout) {
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *map =
      [NSMutableDictionary dictionary];
  if (layout == nullptr) {
    return map;
  }
  const std::vector<UInt32> modifiers = {0, shiftKey};
  for (UInt16 key_code = 0; key_code < 128; key_code++) {
    for (UInt32 modifier : modifiers) {
      NSString *text = translateKeyCode(layout, key_code, modifier);
      if (text == nil || text.length == 0) {
        continue;
      }
      if (map[text] == nil) {
        map[text] = @[@(key_code), @(modifier)];
      }
    }
  }
  return map;
}

NSString *convertTextBetweenLayouts(NSString *text,
                                    TISInputSourceRef source_from,
                                    TISInputSourceRef source_to) {
  if (text == nil || text.length == 0) {
    return text;
  }

  auto source_layout = layoutForInputSource(source_from);
  auto target_layout = layoutForInputSource(source_to);
  if (source_layout == nullptr || target_layout == nullptr) {
    return text;
  }

  auto key_map = buildKeyMapForLayout(source_layout);
  NSMutableString *result = [NSMutableString string];
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                           options:NSStringEnumerationByComposedCharacterSequences
                        usingBlock:^(NSString *_Nullable substring,
                                     NSRange,
                                     NSRange,
                                     BOOL *_Nonnull) {
                          if (substring == nil || substring.length == 0) {
                            return;
                          }
                          auto mapping = key_map[substring];
                          if (mapping == nil || mapping.count != 2) {
                            [result appendString:substring];
                            return;
                          }
                          auto key_code = static_cast<UInt16>(mapping[0].intValue);
                          auto modifiers = static_cast<UInt32>(mapping[1].unsignedIntValue);
                          NSString *converted =
                              translateKeyCode(target_layout, key_code, modifiers);
                          if (converted == nil || converted.length == 0) {
                            [result appendString:substring];
                          } else {
                            [result appendString:converted];
                          }
                        }];
  return result;
}

int findInputSourceIndex(const std::vector<TISInputSourceRef> &sources,
                         TISInputSourceRef source) {
  for (int i = 0; i < sources.size(); i++) {
    if (isSameInputSource(sources[i], source)) {
      return i;
    }
  }
  return -1;
}

bool getCurrentAndNextInputSources(TISInputSourceRef *current,
                                   TISInputSourceRef *next) {
  if (current == nullptr || next == nullptr) {
    return false;
  }

  CFArrayRef source_list = TISCreateInputSourceList(nullptr, false);
  if (source_list == nullptr) {
    return false;
  }

  std::vector<TISInputSourceRef> enabled_keyboard_sources;
  auto count = CFArrayGetCount(source_list);
  for (CFIndex i = 0; i < count; i++) {
    auto source = reinterpret_cast<TISInputSourceRef>(const_cast<void *>(
        CFArrayGetValueAtIndex(source_list, i)));
    auto category = static_cast<CFStringRef>(
        TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory));
    if (category == nullptr ||
        CFStringCompare(category, kTISCategoryKeyboardInputSource, 0) !=
            kCFCompareEqualTo) {
      continue;
    }
    auto enabled = static_cast<CFBooleanRef>(
        TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled));
    if (enabled != nullptr && !CFBooleanGetValue(enabled)) {
      continue;
    }
    if (layoutForInputSource(source) == nullptr) {
      continue;
    }
    enabled_keyboard_sources.push_back(source);
  }

  if (enabled_keyboard_sources.size() < 2) {
    CFRelease(source_list);
    return false;
  }

  TISInputSourceRef current_input_source = TISCopyCurrentKeyboardInputSource();
  int current_index =
      findInputSourceIndex(enabled_keyboard_sources, current_input_source);
  if (current_index < 0) {
    TISInputSourceRef current_layout_source =
        TISCopyCurrentKeyboardLayoutInputSource();
    current_index =
        findInputSourceIndex(enabled_keyboard_sources, current_layout_source);
    if (current_layout_source != nullptr) {
      CFRelease(current_layout_source);
    }
  }
  if (current_input_source != nullptr) {
    CFRelease(current_input_source);
  }

  if (current_index < 0) {
    CFRelease(source_list);
    return false;
  }

  int next_index = (current_index + 1) % enabled_keyboard_sources.size();
  *current = enabled_keyboard_sources[current_index];
  *next = enabled_keyboard_sources[next_index];
  CFRetain(*current);
  CFRetain(*next);

  CFRelease(source_list);
  return true;
}

NSString *replaceRegex(NSString *text,
                       NSString *pattern,
                       NSString *template_string) {
  NSError *error = nil;
  NSRegularExpression *regex =
      [NSRegularExpression regularExpressionWithPattern:pattern
                                                options:0
                                                  error:&error];
  if (regex == nil || error != nil) {
    return text;
  }
  return [regex stringByReplacingMatchesInString:text
                                         options:0
                                           range:NSMakeRange(0, text.length)
                                    withTemplate:template_string];
}

NSString *applySentenceCase(NSString *text) {
  NSString *lowercased = [text lowercaseString];
  NSMutableString *result = [lowercased mutableCopy];
  __block bool should_capitalize = true;

  [lowercased
      enumerateSubstringsInRange:NSMakeRange(0, lowercased.length)
                         options:NSStringEnumerationByComposedCharacterSequences
                      usingBlock:^(NSString *_Nullable substring,
                                   NSRange substring_range,
                                   NSRange,
                                   BOOL *_Nonnull) {
                        if (substring == nil || substring.length == 0) {
                          return;
                        }
                        if (should_capitalize &&
                            [substring rangeOfCharacterFromSet:[NSCharacterSet
                                                                   letterCharacterSet]]
                                    .location != NSNotFound) {
                          [result replaceCharactersInRange:substring_range
                                                 withString:[substring
                                                                uppercaseString]];
                          should_capitalize = false;
                          return;
                        }
                        if ([substring isEqualToString:@"."] ||
                            [substring isEqualToString:@"!"] ||
                            [substring isEqualToString:@"?"]) {
                          should_capitalize = true;
                        }
                      }];

  return [result autorelease];
}

} // namespace

std::string applyTextFormat(const std::string &text, TextFormatAction action) {
  @autoreleasepool {
    NSString *input = [NSString stringWithUTF8String:text.c_str()];
    if (input == nil) {
      return text;
    }

    NSString *result = input;
    switch (action) {
      case TextFormatAction::kLowerCase:
        result = [input lowercaseString];
        break;
      case TextFormatAction::kUpperCase:
        result = [input uppercaseString];
        break;
      case TextFormatAction::kCapitalizeWords:
        result = [input capitalizedString];
        break;
      case TextFormatAction::kSentenceCase:
        result = applySentenceCase(input);
        break;
      case TextFormatAction::kRemoveEmptyLines:
        result = replaceRegex(input, @"(?m)^\\s*\\n", @"");
        break;
      case TextFormatAction::kStripAllWhitespaces:
        result = replaceRegex(input, @"\\s+", @"");
        break;
      case TextFormatAction::kTrimSurroundingWhitespaces:
        result = [input stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        break;
    }
    if (result == nil) {
      return text;
    }
    auto utf8 = [result UTF8String];
    if (utf8 == nullptr) {
      return text;
    }
    return utf8;
  }
}

std::string rotateTextInputSource(const std::string &text,
                                  bool *did_switch_input_source) {
  if (did_switch_input_source != nullptr) {
    *did_switch_input_source = false;
  }

  @autoreleasepool {
    TISInputSourceRef current_source = nullptr;
    TISInputSourceRef next_source = nullptr;
    if (!getCurrentAndNextInputSources(&current_source, &next_source)) {
      return text;
    }

    NSString *input = [NSString stringWithUTF8String:text.c_str()];
    if (input == nil) {
      input = @"";
    }
    NSString *converted =
        convertTextBetweenLayouts(input, current_source, next_source);
    __block bool switched = false;
    if ([NSThread isMainThread]) {
      switched = TISSelectInputSource(next_source) == noErr;
    } else {
      dispatch_sync(dispatch_get_main_queue(), ^{
        switched = TISSelectInputSource(next_source) == noErr;
      });
    }
    if (did_switch_input_source != nullptr) {
      *did_switch_input_source = switched;
    }

    CFRelease(current_source);
    CFRelease(next_source);

    if (!switched || converted == nil) {
      return text;
    }
    auto utf8 = [converted UTF8String];
    if (utf8 == nullptr) {
      return text;
    }
    return utf8;
  }
}

bool selectNextInputSource() {
  @autoreleasepool {
    TISInputSourceRef current_source = nullptr;
    TISInputSourceRef next_source = nullptr;
    if (!getCurrentAndNextInputSources(&current_source, &next_source)) {
      return false;
    }
    __block bool switched = false;
    if ([NSThread isMainThread]) {
      switched = TISSelectInputSource(next_source) == noErr;
    } else {
      dispatch_sync(dispatch_get_main_queue(), ^{
        switched = TISSelectInputSource(next_source) == noErr;
      });
    }
    CFRelease(current_source);
    CFRelease(next_source);
    return switched;
  }
}

} // namespace text_formatter_mac
