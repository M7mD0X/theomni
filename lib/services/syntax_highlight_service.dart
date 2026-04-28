import 'package:flutter/material.dart';
import '../theme/omni_theme.dart';

/// Simple regex-based syntax highlighter for Omni-IDE.
///
/// Not a full parser — just enough to make code readable by colouring
/// keywords, strings, numbers, comments, function calls, and type names.

class SyntaxHighlightService {
  // ── Colour map ──────────────────────────────────────────────────────────

  /// Tokens used by [_buildSpans].
  static const _kColorMap = <_Token, Color>{
    _Token.keyword: T.accent,
    _Token.string: T.sage,
    _Token.number: T.coral,
    _Token.comment: T.muted,
    _Token.function: Color(0xFF82AAFF),
    _Token.type: Color(0xFFFF9E80), // warm peach variant of coral
    _Token.control: T.rose,
    _Token.builtin: T.slate,
    _Token.plain: T.text,
  };

  // ── Language detection ──────────────────────────────────────────────────

  /// Returns a language key from a file name / path.
  static String detectLanguage(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot >= 0 ? lower.substring(dot + 1) : '';

    switch (ext) {
      // ── Dart ──
      case 'dart':
        return 'dart';

      // ── JavaScript / TypeScript ──
      case 'js':
      case 'mjs':
      case 'cjs':
      case 'jsx':
        return 'javascript';
      case 'ts':
      case 'tsx':
        return 'typescript';

      // ── Python ──
      case 'py':
      case 'pyi':
        return 'python';

      // ── Kotlin ──
      case 'kt':
      case 'kts':
        return 'kotlin';

      // ── Java ──
      case 'java':
        return 'java';

      // ── C-family ──
      case 'c':
      case 'h':
        return 'c';
      case 'cpp':
      case 'cc':
      case 'cxx':
      case 'hpp':
        return 'cpp';

      // ── Go ──
      case 'go':
        return 'go';

      // ── Rust ──
      case 'rs':
        return 'rust';

      // ── Ruby ──
      case 'rb':
        return 'ruby';

      // ── Swift ──
      case 'swift':
        return 'swift';

      // ── SQL ──
      case 'sql':
        return 'sql';

      // ── Web ──
      case 'html':
      case 'htm':
      case 'xhtml':
        return 'html';
      case 'css':
      case 'scss':
      case 'less':
        return 'css';
      case 'xml':
      case 'xsl':
      case 'xsd':
      case 'svg':
        return 'xml';

      // ── Data formats ──
      case 'json':
        return 'json';
      case 'yaml':
      case 'yml':
        return 'yaml';

      // ── Markdown ──
      case 'md':
      case 'markdown':
        return 'markdown';

      // ── Shell ──
      case 'sh':
      case 'bash':
      case 'zsh':
        return 'shell';

      // ── Special / no-highlight ──
      case 'env':
        return 'env';
      case 'gitignore':
      case 'dockerignore':
        return 'gitignore';
      case 'txt':
      case 'log':
        return 'plaintext';

      default:
        return 'generic';
    }
  }

  // ── Public entry point ──────────────────────────────────────────────────

  /// Highlights a single line of [code] for the given [fileName].
  ///
  /// Returns a list of [TextSpan] with the mono font baked in.
  static List<TextSpan> highlight(String code, String fileName) {
    final lang = detectLanguage(fileName);
    return _highlightForLanguage(code, lang);
  }

  // ── Internal routing ────────────────────────────────────────────────────

  static List<TextSpan> _highlightForLanguage(String code, String lang) {
    switch (lang) {
      case 'dart':
        return _highlightWithRules(code, _dartRules);
      case 'javascript':
      case 'typescript':
        return _highlightWithRules(code, _jsRules);
      case 'python':
        return _highlightWithRules(code, _pythonRules);
      case 'kotlin':
        return _highlightWithRules(code, _kotlinRules);
      case 'java':
        return _highlightWithRules(code, _javaRules);
      case 'c':
        return _highlightWithRules(code, _cRules);
      case 'cpp':
        return _highlightWithRules(code, _cppRules);
      case 'go':
        return _highlightWithRules(code, _goRules);
      case 'rust':
        return _highlightWithRules(code, _rustRules);
      case 'ruby':
        return _highlightWithRules(code, _rubyRules);
      case 'swift':
        return _highlightWithRules(code, _swiftRules);
      case 'sql':
        return _highlightWithRules(code, _sqlRules);
      case 'html':
      case 'xml':
        return _highlightWithRules(code, _xmlRules);
      case 'css':
        return _highlightWithRules(code, _cssRules);
      case 'json':
        return _highlightWithRules(code, _jsonRules);
      case 'yaml':
        return _highlightWithRules(code, _yamlRules);
      case 'markdown':
        return _highlightWithRules(code, _mdRules);
      case 'shell':
        return _highlightWithRules(code, _shellRules);
      case 'env':
      case 'gitignore':
      case 'plaintext':
      default:
        return _plainSpans(code);
    }
  }

  // ── Tokeniser engine ────────────────────────────────────────────────────

  /// Runs a list of [_HighlightRule] over [code] in priority order.
  ///
  /// Earlier rules take precedence. The engine works character-by-character,
  /// trying each rule's regex at the current position. The first match wins.
  static List<TextSpan> _highlightWithRules(
    String code,
    List<_HighlightRule> rules,
  ) {
    final spans = <TextSpan>[];
    var i = 0;
    final len = code.length;

    while (i < len) {
      _HighlightRule? matchedRule;
      String? matchedText;

      for (final rule in rules) {
        final match = rule.pattern.matchAsPrefix(code, i);
        if (match != null) {
          matchedRule = rule;
          matchedText = match.group(0);
          break;
        }
      }

      if (matchedRule != null && matchedText != null) {
        final token = matchedRule.token;
        final color = _kColorMap[token] ?? T.text;
        spans.add(TextSpan(text: matchedText, style: TextStyle(color: color)));
        i += matchedText.length;
      } else {
        // Consume one plain character
        spans.add(TextSpan(text: code[i], style: const TextStyle(color: T.text)));
        i++;
      }
    }

    return spans;
  }

  /// Just return the entire line as plain text.
  static List<TextSpan> _plainSpans(String code) {
    return [TextSpan(text: code, style: const TextStyle(color: T.text))];
  }

  // ════════════════════════════════════════════════════════════════════════
  // RULE DEFINITIONS
  // ════════════════════════════════════════════════════════════════════════

  // ── Dart ────────────────────────────────────────────────────────────────

  static final _dartRules = <_HighlightRule>[
    // Multi-line comment start (consume rest of line)
    const _HighlightRule(r'/\*.*', _Token.comment),
    // Single-line comment
    const _HighlightRule(r'//.*', _Token.comment),
    // Triple-quoted strings
    const _HighlightRule(r"'''(?:[^'\\]|\\.)*'''", _Token.string),
    const _HighlightRule(r'"""(?:[^"\\]|\\.)*"""', _Token.string),
    // Double-quoted string
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    // Single-quoted string
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    // Multi-char operator
    const _HighlightRule(r'=>|==|!=|<=|>=|\?\?|\.\.|\?\.|\??\.', _Token.plain),
    // Numbers
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)\b',
      _Token.number,
    ),
    // Keywords
    const _HighlightRule(
      r'\b(?:if|else|for|while|do|switch|case|break|continue|return|try|catch|'
      r'finally|throw|rethrow|class|abstract|interface|enum|mixin|extends|implements|'
      r'import|export|library|part|of|show|hide|as|is|in|new|this|super|'
      r'static|const|final|var|late|void|dynamic|Function|typedef|extension|'
      r'on|with|await|async|yield|sync\*|async\*|factory|get|set|operator|'
      r'required|covariant|external|true|false|null)\b',
      _Token.keyword,
    ),
    // Built-in types
    const _HighlightRule(
      r'\b(?:int|double|num|bool|String|List|Map|Set|Duration|DateTime|Uri|'
      r'BigInt|Record|Symbol|Type|Object|Future|Stream|Iterable|Iterator|'
      r'Never|Function|Runes|RegExp|Comparable|Pattern|Match|RegExpMatch)\b',
      _Token.type,
    ),
    // Function calls — identifier followed by (
    _HighlightRule(r'\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*\()', _Token.function),
  ];

  // ── JavaScript / TypeScript ─────────────────────────────────────────────

  static final _jsRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Template literal (simplified: consume to backtick on same line)
    _HighlightRule(r'`(?:[^`\\]|\\.)*`', _Token.string),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    const _HighlightRule(r'=>|===|!==|==|!=|<=|>=|&&|\|\||\?\?|\.\.\.', _Token.plain),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?[nNmM]?)\b',
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:if|else|for|while|do|switch|case|break|continue|return|try|catch|'
      r'finally|throw|class|enum|extends|implements|import|export|from|default|'
      r'new|this|super|static|const|let|var|typeof|instanceof|in|of|delete|'
      r'void|yield|await|async|function|true|false|null|undefined|NaN|Infinity)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:console|window|document|Math|JSON|Object|Array|String|Number|'
      r'Boolean|Symbol|BigInt|Map|Set|WeakMap|WeakSet|Promise|Error|'
      r'RegExp|Date|parseInt|parseFloat|setTimeout|setInterval|'
      r'clearTimeout|clearInterval|require|module|exports|process)\b',
      _Token.builtin,
    ),
    // TypeScript-specific
    const _HighlightRule(
      r'\b(?:interface|type|namespace|declare|readonly|keyof|infer|is|asserts|'
      r'satisfies|override|accessor|using|async)\b',
      _Token.keyword,
    ),
    _HighlightRule(r'\b[A-Z][a-zA-Z0-9]*\b', _Token.type),
    _HighlightRule(r'\b[a-zA-Z_$][a-zA-Z0-9_$]*(?=\s*\()', _Token.function),
  ];

  // ── Python ──────────────────────────────────────────────────────────────

  static final _pythonRules = <_HighlightRule>[
    const _HighlightRule(r'#.*', _Token.comment),
    // Triple-quoted strings (multi-line handled per-line by consuming greedily)
    const _HighlightRule(r'"""(?:[^"\\]|\\.)*"""', _Token.string),
    const _HighlightRule(r"'''(?:[^'\\]|\\.)*'''", _Token.string),
    _HighlightRule(r'f"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"f'(?:[^'\\]|\\.)*'", _Token.string),
    _HighlightRule(r'r"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"r'(?:[^'\\]|\\.)*'", _Token.string),
    _HighlightRule(r'b"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"b'(?:[^'\\]|\\.)*'", _Token.string),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?j?)\b',
      _Token.number,
    ),
    // Decorators
    const _HighlightRule(r'@\w+', _Token.control),
    const _HighlightRule(
      r'\b(?:if|elif|else|for|while|break|continue|return|try|except|finally|'
      r'raise|with|as|import|from|class|def|lambda|pass|del|global|nonlocal|'
      r'yield|await|async|assert|and|or|not|in|is|True|False|None)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:int|float|str|bool|list|dict|tuple|set|frozenset|bytes|bytearray|'
      r'memoryview|complex|range|type|object|super|print|len|input|open|'
      r'Exception|ValueError|TypeError|KeyError|IndexError|RuntimeError|'
      r'NotImplementedError|AttributeError|ImportError|OSError)\b',
      _Token.builtin,
    ),
    // "self" and "cls" as keywords
    const _HighlightRule(r'\b(?:self|cls)\b', _Token.control),
    _HighlightRule(r'\bdef\s+(\w+)', _Token.function),
    // Function calls
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*\()', _Token.function),
  ];

  // ── Kotlin ──────────────────────────────────────────────────────────────

  static final _kotlinRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?[fFdDlLuU]?)\b',
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:if|else|when|for|while|do|break|continue|return|try|catch|finally|'
      r'throw|class|object|interface|enum|annotation|sealed|data|open|abstract|'
      r'final|override|private|protected|public|internal|companion|init|constructor|'
      r'import|package|as|is|in|!in|typealias|val|var|fun|suspend|inline|reified|'
      r'crossinline|noinline|tailrec|operator|infix|true|false|null|this|super|'
      r'by|lazy|where|actual|expect)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:Int|Long|Short|Byte|Float|Double|Boolean|Char|String|Unit|'
      r'Nothing|Any|List|Map|Set|MutableList|MutableMap|MutableSet|Array|'
      r'Sequence|Pair|Triple|Result|IntRange|UInt|ULong|Number)\b',
      _Token.type,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*[\(<])', _Token.function),
  ];

  // ── Java ────────────────────────────────────────────────────────────────

  static final _javaRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Annotations
    const _HighlightRule(r'@\w+', _Token.control),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    const _HighlightRule(
      r"\b(?:0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?[fFdDlL]?)\b",
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:if|else|for|while|do|switch|case|break|continue|return|try|catch|'
      r'finally|throw|throws|class|interface|enum|extends|implements|import|'
      r'package|new|this|super|static|final|void|abstract|synchronized|'
      r'volatile|transient|native|strictfp|assert|default|instanceof|'
      r'true|false|null|record|sealed|permits|non-sealed|var|yield)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:int|long|short|byte|float|double|boolean|char|String|Integer|Long|'
      r'Short|Byte|Float|Double|Boolean|Character|Object|Class|Throwable|'
      r'Exception|RuntimeException|List|ArrayList|Map|HashMap|Set|HashSet|'
      r'Queue|Deque|LinkedList|Optional|Stream|StringBuilder|StringBuffer)\b',
      _Token.type,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*\()', _Token.function),
  ];

  // ── C ───────────────────────────────────────────────────────────────────

  static final _cRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Preprocessor
    const _HighlightRule(r'#\s*\w+', _Token.control),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)'", _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?[uUlL]*)\b',
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:if|else|for|while|do|switch|case|break|continue|return|goto|'
      r'typedef|struct|enum|union|sizeof|extern|static|register|volatile|'
      r'const|signed|unsigned|inline|void|char|short|int|long|float|double|'
      r'auto|restrict|_Alignas|_Alignof|_Atomic|_Bool|_Complex|_Generic|'
      r'_Imaginary|_Noreturn|_Static_assert|_Thread_local|'
      r'true|false|NULL)\b',
      _Token.keyword,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*\()', _Token.function),
  ];

  // ── C++ ─────────────────────────────────────────────────────────────────

  static final _cppRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Preprocessor
    const _HighlightRule(r'#\s*(?:include|define|ifdef|ifndef|endif|if|else|elif|'
        r'undef|pragma|error|warning|line)\b.*', _Token.control),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)'", _Token.string),
    // Raw string literals (simplified)
    const _HighlightRule(r'R"[^(]*\([^)]*\)"', _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F]+[uUlL]*|[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?[uUlLfF]*)\b',
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:if|else|for|while|do|switch|case|break|continue|return|goto|'
      r'class|struct|enum|union|namespace|using|template|typename|concept|'
      r'requires|public|private|protected|virtual|override|final|constexpr|'
      r'consteval|constinit|static_assert|noexcept|throw|try|catch|new|delete|'
      r'this|operator|sizeof|typedef|auto|void|char|short|int|long|float|double|'
      r'bool|wchar_t|char16_t|char32_t|char8_t|signed|unsigned|inline|static|'
      r'extern|register|volatile|const|friend|explicit|mutable|thread_local|'
      r'true|false|nullptr)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:std|string|vector|map|set|unordered_map|unordered_set|array|'
      r'shared_ptr|unique_ptr|weak_ptr|optional|variant|tuple|pair|'
      r'size_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t)\b',
      _Token.builtin,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*[\(<])', _Token.function),
  ];

  // ── Go ──────────────────────────────────────────────────────────────────

  static final _goRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Raw string literal
    const _HighlightRule(r'`(?:[^`\\]|\\.)*`', _Token.string),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'[^']'", _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)\b',
      _Token.number,
    ),
    const _HighlightRule(
      r'\b(?:break|case|chan|const|continue|default|defer|else|fallthrough|'
      r'for|func|go|goto|if|import|interface|map|package|range|return|select|'
      r'struct|switch|type|var|true|false|nil|iota)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|'
      r'float32|float64|complex64|complex128|byte|rune|string|bool|error|'
      r'any|comparable|append|cap|close|copy|delete|len|make|new|panic|'
      r'print|println|recover|true|false|nil)\b',
      _Token.builtin,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*\()', _Token.function),
  ];

  // ── Rust ────────────────────────────────────────────────────────────────

  static final _rustRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    // Doc comments
    const _HighlightRule(r'///.*', _Token.comment),
    const _HighlightRule(r'//!.*', _Token.comment),
    // Raw strings
    const _HighlightRule(r'r#*"(?:[^"\\]|\\.)*"#*', _Token.string),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'[^'\\]|\\.'", _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?(?:_f32|_f64|f32|f64|usize|isize|i8|i16|i32|i64|i128|u8|u16|u32|u64|u128)?)\b',
      _Token.number,
    ),
    // Attributes
    const _HighlightRule(r'#!?\[.*?\]', _Token.control),
    const _HighlightRule(
      r'\b(?:as|async|await|break|const|continue|crate|dyn|else|enum|extern|'
      r'fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|self|'
      r'Self|static|struct|super|trait|type|unsafe|use|where|while|yield|'
      r'true|false)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|'
      r'f32|f64|bool|char|str|String|Vec|Box|Rc|Arc|Option|Result|'
      r'HashMap|HashSet|BTreeMap|BTreeSet|Cow|Range|Duration|'
      r'println|eprintln|format|vec|panic|assert|todo|unimplemented|'
      r'unreachable|dbg| Ok|Err|Some|None)\b',
      _Token.builtin,
    ),
    // Macro calls
    const _HighlightRule(r'\b[a-zA-Z_]\w*!', _Token.control),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*[\(<])', _Token.function),
  ];

  // ── Ruby ────────────────────────────────────────────────────────────────

  static final _rubyRules = <_HighlightRule>[
    const _HighlightRule(r'=begin\b.*=end\b', _Token.comment),
    const _HighlightRule(r'#.*', _Token.comment),
    const _HighlightRule(r':\w+', _Token.string), // symbols
    const _HighlightRule(r'(?<!\w)"(?:[^"\\]|\\.)*"', _Token.string),
    const _HighlightRule(r"(?<!\w)'(?:[^'\\]|\\.)*'", _Token.string),
    const _HighlightRule(r'\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?[ri]?)\b',
        _Token.number),
    const _HighlightRule(
      r'\b(?:if|elsif|else|unless|for|while|until|case|when|break|next|redo|'
      r'return|begin|rescue|ensure|raise|def|class|module|end|do|then|yield|'
      r'block_given\?|proc|lambda|require|include|extend|attr_reader|attr_writer|'
      r'attr_accessor|private|protected|public|true|false|nil|self|super|'
      r'and|or|not|in|defined\?)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:puts|print|p|gets|chomp|to_s|to_i|to_f|to_a|to_h|length|size|'
      r'each|map|select|reject|reduce|inject|sort|reverse|join|split|'
      r'Array|Hash|Set|String|Integer|Float|Numeric|Range|Regexp|'
      r'Time|Date|File|Dir|IO|Exception|StandardError|RuntimeError|ArgumentError)\b',
      _Token.builtin,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*[?!]?(?=\s*[\(<])', _Token.function),
    // Method definitions
    const _HighlightRule(r'\bdef\s+\w+', _Token.keyword),
  ];

  // ── Swift ───────────────────────────────────────────────────────────────

  static final _swiftRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*', _Token.comment),
    const _HighlightRule(r'//.*', _Token.comment),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)\b',
      _Token.number,
    ),
    // @property / @available
    const _HighlightRule(r'@\w+', _Token.control),
    const _HighlightRule(
      r'\b(?:if|else|switch|case|break|continue|return|for|in|while|repeat|'
      r'guard|throw|try|catch|throw|defer|do|class|struct|enum|protocol|'
      r'extension|import|let|var|func|init|deinit|subscript|typealias|'
      r'associatedtype|where|as|is|nil|self|super|static|mutating|'
      r'override|public|private|internal|open|fileprivate|weak|unowned|'
      r'lazy|convenience|required|final|indirect|inout|operator|true|false)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64|'
      r'Float|Double|Bool|String|Character|Array|Dictionary|Set|Optional|'
      'Result|Range|ClosedRange|Any|AnyObject|Never|Void|Self|Type|'
      r'Date|URL|Data|UUID|Error)\b',
      _Token.type,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*[\(<])', _Token.function),
  ];

  // ── SQL ─────────────────────────────────────────────────────────────────

  static final _sqlRules = <_HighlightRule>[
    const _HighlightRule(r'--.*', _Token.comment),
    const _HighlightRule(r'/\*.*', _Token.comment),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    const _HighlightRule(
      r'\b(?:SELECT|FROM|WHERE|AND|OR|NOT|IN|EXISTS|BETWEEN|LIKE|IS|NULL|'
      r'INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|DROP|ALTER|ADD|'
      r'INDEX|VIEW|JOIN|INNER|LEFT|RIGHT|OUTER|FULL|CROSS|ON|AS|ORDER|BY|'
      r'GROUP|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|CASE|WHEN|THEN|ELSE|END|'
      r'TRANSACTION|BEGIN|COMMIT|ROLLBACK|GRANT|REVOKE|EXPLAIN|ANALYZE|'
      r'PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|CHECK|UNIQUE|'
      r'ASC|DESC|TRUE|FALSE|WITH|RECURSIVE|OVER|PARTITION|ROW|RANGE|'
      r'COALESCE|NULLIF|CAST|EXTRACT|COUNT|SUM|AVG|MIN|MAX|IF|IFNULL)\b',
      _Token.keyword,
    ),
    const _HighlightRule(
      r'\b(?:INT|INTEGER|BIGINT|SMALLINT|TINYINT|FLOAT|DOUBLE|DECIMAL|'
      r'NUMERIC|VARCHAR|CHAR|TEXT|BLOB|DATE|TIME|DATETIME|TIMESTAMP|'
      r'BOOLEAN|BOOL|SERIAL|AUTOINCREMENT|UUID|JSON|JSONB)\b',
      _Token.type,
    ),
    _HighlightRule(r'\b[a-zA-Z_]\w*(?=\s*\()', _Token.function),
  ];

  // ── HTML / XML ──────────────────────────────────────────────────────────

  static final _xmlRules = <_HighlightRule>[
    const _HighlightRule(r'<!--.*-->', _Token.comment),
    // Processing instruction
    const _HighlightRule(r'<\?.*\?>', _Token.control),
    // Closing tag
    const _HighlightRule(r'</\s*[a-zA-Z][\w:-]*\s*>', _Token.keyword),
    // Opening tag — tag name
    const _HighlightRule(r'<\s*([a-zA-Z][\w:-]*)', _Token.keyword),
    // Attribute values
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    // Attribute names
    _HighlightRule(r'\b[a-zA-Z_:][\w:.-]*(?=\s*=)', _Token.function),
    // Self-closing slash
    const _HighlightRule(r'/\s*>', _Token.keyword),
    // Entity references
    const _HighlightRule(r'&\w+;', _Token.number),
  ];

  // ── CSS ─────────────────────────────────────────────────────────────────

  static final _cssRules = <_HighlightRule>[
    const _HighlightRule(r'/\*.*\*/', _Token.comment),
    // At-rules
    const _HighlightRule(r'@[a-zA-Z-]+\b', _Token.control),
    // Strings
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    // Numbers with units
    const _HighlightRule(
      r'\b(?:[0-9]*\.[0-9]+|[0-9]+)(?:px|em|rem|vh|vw|vmin|vmax|%'
        r'|deg|rad|turn|s|ms|fr|ch|ex|pt|pc|in|cm|mm|dppx|dpi|dpcm)?\b',
      _Token.number,
    ),
    // Hex colours
    const _HighlightRule(r'#[0-9a-fA-F]{3,8}\b', _Token.number),
    // Properties
    _HighlightRule(
      r'\b(?:color|background|background-color|background-image|border|border-radius|'
      r'margin|padding|display|flex|grid|position|top|right|bottom|left|width|height|'
      r'font-size|font-weight|font-family|line-height|text-align|text-decoration|'
      r'overflow|z-index|opacity|box-shadow|transform|transition|animation|'
      r'gap|justify-content|align-items|align-self|flex-direction|flex-wrap|'
      r'min-width|max-width|min-height|max-height|cursor|outline|visibility|'
      r'white-space|word-break|content|appearance|filter|backdrop-filter|'
      r'text-overflow|scrollbar-width|scroll-snap-type|inset|place-[\w-]+)\s*(?=:)',
      _Token.function,
    ),
    // Values
    const _HighlightRule(
      r'\b(?:none|auto|inherit|initial|unset|revert|block|inline|inline-block|'
      r'flex|grid|inline-flex|inline-grid|absolute|relative|fixed|sticky|'
      r'hidden|visible|scroll|transparent|solid|dashed|dotted|center|left|'
      r'right|top|bottom|space-between|space-around|space-evenly|column|row|'
      r'wrap|nowrap|bold|normal|italic|uppercase|lowercase|capitalize|'
      r'ease|ease-in|ease-out|ease-in-out|linear|both|forwards|'
      r'pointer|default|not-allowed|grab|pointer|border-box|content-box|'
      r'pre|pre-wrap|pre-line|break-all|break-word)\b',
      _Token.type,
    ),
    // !important
    const _HighlightRule(r'!important', _Token.control),
  ];

  // ── JSON ────────────────────────────────────────────────────────────────

  static final _jsonRules = <_HighlightRule>[
    // Keys
    _HighlightRule(r'"(\w[^"\\]*(?:\\.[^"\\]*)*)"\s*(?=:)', _Token.function),
    // Strings
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    // Numbers
    const _HighlightRule(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
      _Token.number,
    ),
    // Boolean / null
    const _HighlightRule(r'\b(?:true|false|null)\b', _Token.keyword),
  ];

  // ── YAML ────────────────────────────────────────────────────────────────

  static final _yamlRules = <_HighlightRule>[
    const _HighlightRule(r'#.*', _Token.comment),
    // Keys (word followed by colon)
    _HighlightRule(r'\b[\w][\w. -]*\s*(?=:)', _Token.function),
    // Strings
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'(?:[^'\\]|\\.)*'", _Token.string),
    // Booleans
    const _HighlightRule(r'\b(?:true|false|yes|no|on|off)\b', _Token.keyword),
    // Null
    const _HighlightRule(r'\b(?:null|~)\b', _Token.keyword),
    // Numbers
    const _HighlightRule(
      r'\b(?:0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?'
        r'|\.inf|\.nan)\b',
      _Token.number,
    ),
    // Anchors & aliases
    const _HighlightRule(r'&\w+', _Token.control),
    const _HighlightRule(r'\*\w+', _Token.control),
    // Directives
    const _HighlightRule(r'---', _Token.control),
    const _HighlightRule(r'\.\.\.', _Token.control),
    // Tag
    const _HighlightRule(r'!!\w+', _Token.type),
  ];

  // ── Markdown ────────────────────────────────────────────────────────────

  static final _mdRules = <_HighlightRule>[
    // Headings
    const _HighlightRule(r'^#{1,6}\s', _Token.keyword),
    // Code fences
    const _HighlightRule(r'^```.*', _Token.control),
    const _HighlightRule(r'^\s*```', _Token.control),
    // Bold
    const _HighlightRule(r'\*\*[^*]+\*\*', _Token.keyword),
    const _HighlightRule(r'__[^_]+__', _Token.keyword),
    // Italic
    const _HighlightRule(r'\*[^*]+\*', _Token.type),
    const _HighlightRule(r'_[^_]+_', _Token.type),
    // Strikethrough
    const _HighlightRule(r'~~[^~]+~~', _Token.comment),
    // Inline code
    _HighlightRule(r'`[^`]+`', _Token.string),
    // Links
    const _HighlightRule(r'!?\[[^\]]*\]\([^)]*\)', _Token.function),
    // Blockquote
    const _HighlightRule(r'^>\s?', _Token.control),
    // Horizontal rule
    const _HighlightRule(r'^(?:---|\*\*\*|___)\s*$', _Token.control),
    // List markers
    const _HighlightRule(r'^\s*[-*+]\s', _Token.keyword),
    const _HighlightRule(r'^\s*\d+\.\s', _Token.number),
  ];

  // ── Shell ───────────────────────────────────────────────────────────────

  static final _shellRules = <_HighlightRule>[
    const _HighlightRule(r'#.*', _Token.comment),
    // Strings
    _HighlightRule(r'"(?:[^"\\]|\\.)*"', _Token.string),
    _HighlightRule(r"'[^']*'", _Token.string),
    // Variables
    const _HighlightRule(r'\$\{[^}]+\}', _Token.type),
    const _HighlightRule(r'\$\w+', _Token.type),
    // Numbers
    const _HighlightRule(r'\b[0-9]+\b', _Token.number),
    // Keywords
    const _HighlightRule(
      r'\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|in|'
      r'function|return|exit|local|export|readonly|declare|typeset|unset|'
      r'set|shift|source|alias|unalias|echo|printf|read|cd|pwd|ls|mkdir|'
      r'rm|cp|mv|cat|grep|sed|awk|find|sort|uniq|wc|head|tail|tee|xargs|'
      r'curl|wget|chmod|chown|sudo|apt|brew|pip|npm|yarn|docker|kubectl|'
      r'true|false)\b',
      _Token.keyword,
    ),
    // Shebang
    const _HighlightRule(r'^#!\s*/\S+', _Token.control),
    // Operators
    const _HighlightRule(r'&&|\|\||;;|<<|>>|&|\|', _Token.control),
  ];
}

// ════════════════════════════════════════════════════════════════════════════
// HELPER TYPES
// ════════════════════════════════════════════════════════════════════════════

/// Token types recognised by the highlighter.
enum _Token {
  keyword,
  string,
  number,
  comment,
  function,
  type,
  control,
  builtin,
  plain,
}

/// A single highlighting rule: a regex + the token it produces.
class _HighlightRule {
  final RegExp pattern;
  final _Token token;

  const _HighlightRule(String pattern, this.token)
      : pattern = RegExp(pattern);
}

/// Container for a highlighted line — a list of coloured [TextSpan]s.
///
/// Wrap a [Text] widget with `rich: true` to display these spans.
class HighlightedLine {
  final List<TextSpan> spans;
  const HighlightedLine(this.spans);
}
