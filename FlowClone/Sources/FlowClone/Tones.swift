import Foundation

/// Writing-tone presets applied by the cleanup LLM. Tone adjusts STYLE only —
/// the prompt forbids adding/removing information.
struct Tone: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    let description: String
    /// Appended to the cleanup system prompt ("" = faithful default).
    let instruction: String
    /// Shown on the Style card: what "let's grab lunch tomorrow to discuss" becomes.
    let example: String

    /// True for the no-AI mode: paste the raw transcription untouched.
    var isVerbatim: Bool { id == "verbatim" }

    static let all: [Tone] = [
        Tone(id: "verbatim", name: "Verbatim", emoji: "📝",
             description: "Exactly as transcribed. No AI cleanup at all — fillers and stumbles included.",
             instruction: "",
             example: "um so let's grab lunch tomorrow to uh discuss."),
        Tone(id: "default", name: "Faithful", emoji: "🎯",
             description: "Cleans up fillers and grammar, keeps your exact voice.",
             instruction: "",
             example: "Let's grab lunch tomorrow to discuss."),
        Tone(id: "super-casual", name: "Super Casual", emoji: "🤙",
             description: "Texting mode. Lowercase, breezy, zero stiffness.",
             instruction: """
             Rewrite in a super casual, laid-back texting style. ALWAYS: start lowercase, \
             use contractions and casual forms ("wanna", "gonna", "gotta" where natural), \
             drop stiff or wordy phrasing, keep it short and breezy. Trailing period \
             optional; question marks stay.
             Example: "I want you to go out on a date with me." → "wanna go out on a date \
             with me?"
             Example: "Can you send me the report when you have time?" → "send me the \
             report when you get a sec?"
             Example: "That sounds like a good plan." → "sounds like a plan"
                          Bulgarian example: "Можеш ли да ми пратиш доклада, когато имаш време?" → \
             "прати ми доклада като имаш секунда?"
             """,
             example: "lunch tomorrow? let's talk it over"),
        Tone(id: "casual", name: "Casual", emoji: "😊",
             description: "Friendly and relaxed, like talking to a teammate you like.",
             instruction: """
             Rewrite in a relaxed, friendly, conversational tone — like texting a friend \
             you like. ALWAYS use contractions, direct address, and natural spoken \
             phrasing; soften stiff constructions.
             Example: "I want you to go out on a date with me." → "Want to go out on a \
             date with me?"
             Example: "I am unable to attend the meeting." → "I can't make the meeting."
             Example: "Please provide the document." → "Can you send over the doc?"
                          Bulgarian example: "Моля, изпратете документа." → "Може ли да ми пратиш \
             документа?"
             """,
             example: "Want to grab lunch tomorrow and talk it through?"),
        Tone(id: "gentlemanly", name: "Gentlemanly", emoji: "🎩",
             description: "Elegant and courteous, like a well-mannered English gentleman.",
             instruction: """
             Rewrite with the elegance and courtesy of a well-mannered English gentleman. \
             Favor gracious, elevated phrasing: "Would you be so kind as to…", "I should \
             be delighted to…", "Might I suggest…", "I trust…", "rather", "indeed", \
             "splendid". Prefer refined verbs (purchase, endeavour, ring) over plain ones \
             (buy, try, call). Add a courteous flourish where natural. Never carry spoken \
             artifacts like "oh wait" or "you know" into the result.
             Example: "can you send me the report" → "Would you be so kind as to send me \
             the report?"
             Example: "I need to buy milk and eggs" → "I shall need to purchase milk and \
             eggs."
             LANGUAGE RULE: reply in the SAME language as the transcript — a Bulgarian \
             transcript gets a Bulgarian gentleman, never an English translation. In \
             Bulgarian use the polite plural (Вие) and courteous constructions: \
             "Бихте ли били така любезни да…", "Ще Ви бъда признателен, ако…".
             Bulgarian example: "можеш ли да ми пратиш доклада" → "Бихте ли били така \
             любезни да ми изпратите доклада?"
             """,
             example: "Would you be so kind as to join me for luncheon tomorrow?"),
        Tone(id: "work", name: "Work", emoji: "💼",
             description: "Professional and clear. Neutral business language.",
             instruction: """
             Rewrite in a professional workplace tone: clear, concise, courteous-neutral \
             business language. Soften blunt demands into polite requests; prefer \
             precise, professional phrasing.
             Example: "I want you to go out on a date with me." → "Would you be \
             interested in going out on a date with me?"
             Example: "send me the numbers" → "Could you send me the numbers when you \
             get a chance?"
             Example: "this is wrong, fix it" → "I noticed an issue here — could you \
             take another look?"
                          Bulgarian example: "прати ми числата" → "Би ли ми изпратил числата, когато \
             имаш възможност?"
             """,
             example: "Could we meet over lunch tomorrow to discuss this?"),
        Tone(id: "formal", name: "Formal", emoji: "🏛️",
             description: "Proper prose. No contractions, precise vocabulary.",
             instruction: """
             Rewrite in a formal register: no contractions, precise vocabulary, complete \
             and properly structured sentences. Replace casual idioms and blunt phrasing \
             with formal equivalents; prefer constructions like "I would like to", \
             "I would be grateful if".
             Example: "I want you to go out on a date with me." → "I would like to \
             invite you to join me on a date."
             Example: "can you push the meeting" → "Would it be possible to postpone \
             the meeting?"
             Example: "thanks a lot for the help" → "Thank you very much for your \
             assistance."
                          Bulgarian example: "мерси много за помощта" → "Благодаря Ви много за \
             съдействието."
             """,
             example: "I would like to propose that we meet for lunch tomorrow to discuss this matter."),
    ]

    static var current: Tone {
        all.first { $0.id == Settings.tone } ?? all.first { $0.id == "default" }!
    }
}
