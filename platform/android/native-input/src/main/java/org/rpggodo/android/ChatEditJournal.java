package org.rpggodo.android;

import java.util.ArrayList;
import java.util.List;

/** UI-thread journal. Ranges are Unicode code points in the preceding native
 * text, never in a guessed final diff. Godot owns identities and wire limits. */
final class ChatEditJournal {
    static final class Edit {
        final int start, end, group;
        final String text;
        Edit(int start, int end, String text, int group) {
            this.start = start; this.end = end; this.text = text; this.group = group;
        }
    }
    final List<Edit> edits = new ArrayList<>();
    int sequence, baseline, group, selectionStart, selectionEnd;

    void replace(String before, int start, int count, String inserted) {
        edits.add(new Edit(points(before, start), points(before, start + count), inserted, group));
        sequence++;
    }
    void select(int start, int end) {
        if (start != selectionStart || end != selectionEnd) {
            selectionStart = start; selectionEnd = end; sequence++;
        }
    }
    void boundary() { group++; }
    boolean canAccept(int base, int seq, boolean composing) {
        return base == baseline && seq == sequence && !composing;
    }
    void accept(int seq, int start, int end) {
        baseline = sequence = seq;
        selectionStart = start; selectionEnd = end;
        edits.clear();
        group = 0;
    }
    static int points(String value, int offset) {
        int end = Math.max(0, Math.min(offset, value.length()));
        if (end > 0 && end < value.length() && Character.isHighSurrogate(value.charAt(end - 1))
                && Character.isLowSurrogate(value.charAt(end))) end--;
        return value.codePointCount(0, end);
    }
}
