/**
 * Journal text → weighted terms for the word cloud.
 *
 * Two deliberate differences from the kanban dashboard's version, which this
 * replaces:
 *
 *  1. Bigrams. That one was unigram-only, so "deep work", "zone 2" and
 *     "strength training" shattered into their parts and the themes that
 *     actually recur went invisible. A bigram survives here only if the pair
 *     occurs often enough on its own, and its words are then discounted so the
 *     phrase and its halves don't both dominate.
 *  2. Sqrt weighting. Word frequencies are Zipfian; sizing linearly on raw
 *     counts let the top one or two terms swamp everything and flattened the
 *     tail into an unreadable smudge.
 */

/** Function words plus journal-register filler that says nothing about a week. */
const STOPWORDS = new Set([
  // articles, conjunctions, prepositions, pronouns, auxiliaries
  "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "where",
  "who", "what", "how", "why", "is", "are", "was", "were", "be", "been", "being",
  "have", "has", "had", "do", "does", "did", "will", "would", "could", "should",
  "may", "might", "must", "shall", "can", "to", "of", "in", "on", "at", "by",
  "for", "from", "with", "as", "into", "out", "over", "under", "again", "further",
  "once", "here", "there", "all", "any", "both", "each", "few", "more", "most",
  "other", "some", "such", "no", "nor", "not", "only", "own", "same", "so",
  "than", "too", "very", "just", "also", "this", "that", "these", "those", "it",
  "its", "i", "me", "my", "we", "our", "us", "you", "your", "he", "she", "they",
  "them", "their", "his", "her", "about", "after", "before", "between", "through",
  "up", "down", "off", "while", "during", "within", "without", "upon", "toward",
  "towards", "which", "whether", "because", "been",
  // journal register — these describe *any* week, so they drown the signal
  "week", "weekly", "weekend", "day", "days", "time", "times", "felt", "feel",
  "feeling", "overall", "throughout", "although", "despite", "however",
  "particularly", "specifically", "significant", "significantly", "highlighted",
  "highlighting", "contributing", "contributed", "noted", "including", "included",
  "include", "positive", "negative", "remains", "remained", "still", "first",
  "last", "new", "old", "good", "great", "well", "little", "much", "many",
  "like", "led", "due", "one", "two", "three", "amp", "via", "vs", "per",
  "got", "get", "went", "made", "make", "took", "take", "came", "come", "keep",
  "kept", "continued", "continue", "strong", "solid", "nice", "bit", "lot",
  "really", "quite", "though", "even", "back", "around", "across", "along",
  "high", "low", "highs", "lows", "energizers", "stressors",
  // Claude's summarisation register. These rank near the top of every
  // generated High/Low and describe the writing, not the week.
  "additionally", "highlights", "notable", "notably", "reflecting", "moments",
  "sense", "importance", "brought", "leading", "marked", "featured",
  "experiences", "experience", "reflection", "reflections",
  // Day labels survive in journal_raw_text as the template's bullet headers.
  "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  // Contractions the edge-stripping tokenizer leaves whole.
  "you're", "i'm", "it's", "don't", "didn't", "that's", "there's", "doesn't",
  "can't", "won't", "i've", "we've", "isn't", "wasn't",
]);

/** A bigram must appear at least this often before it earns its own entry. */
const MIN_BIGRAM_COUNT = 3;

export type Term = { text: string; count: number; weight: number };

function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9'\-\s]/g, " ")
    .split(/\s+/)
    .map((t) => t.replace(/^['-]+|['-]+$/g, ""))
    .filter((t) => t.length > 2 && !/^\d+$/.test(t));
}

/**
 * Count terms across many texts.
 *
 * Bigrams are formed from adjacent tokens before stopwords are removed, so
 * "zone of focus" can't fuse across a dropped word into a phrase that was
 * never written.
 */
export function countTerms(texts: (string | null | undefined)[], limit = 60): Term[] {
  const unigrams = new Map<string, number>();
  const bigrams = new Map<string, number>();

  for (const raw of texts) {
    if (!raw) continue;
    const tokens = tokenize(raw);

    for (const token of tokens) {
      if (STOPWORDS.has(token)) continue;
      unigrams.set(token, (unigrams.get(token) ?? 0) + 1);
    }

    for (let i = 0; i < tokens.length - 1; i++) {
      const a = tokens[i];
      const b = tokens[i + 1];
      // A phrase worth showing has at least one content word on each side.
      if (STOPWORDS.has(a) || STOPWORDS.has(b)) continue;
      const phrase = `${a} ${b}`;
      bigrams.set(phrase, (bigrams.get(phrase) ?? 0) + 1);
    }
  }

  const kept = new Map<string, number>();
  for (const [phrase, count] of bigrams) {
    if (count < MIN_BIGRAM_COUNT) continue;
    kept.set(phrase, count);
    // Discount the halves by what the phrase already accounts for, so
    // "deep work" doesn't also inflate "deep" and "work".
    for (const part of phrase.split(" ")) {
      const remaining = (unigrams.get(part) ?? 0) - count;
      if (remaining > 0) unigrams.set(part, remaining);
      else unigrams.delete(part);
    }
  }
  for (const [word, count] of unigrams) kept.set(word, count);

  const ranked = [...kept.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit);

  if (!ranked.length) return [];

  // Sqrt compresses the Zipfian head so the tail stays legible.
  const counts = ranked.map(([, c]) => Math.sqrt(c));
  const min = Math.min(...counts);
  const max = Math.max(...counts);
  const span = Math.max(1e-6, max - min);

  return ranked.map(([text, count]) => ({
    text,
    count,
    weight: (Math.sqrt(count) - min) / span, // 0…1
  }));
}
