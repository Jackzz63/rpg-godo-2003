package org.rpggodo.android;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.Spanned;
import android.text.SpannableStringBuilder;
import android.text.TextWatcher;
import android.text.method.PasswordTransformationMethod;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.ActionMode;
import android.view.ContextMenu;
import android.view.Menu;
import android.view.MenuItem;
import org.json.JSONArray;
import org.json.JSONObject;
import org.json.JSONException;
import android.widget.EditText;
import android.widget.FrameLayout;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.util.LinkedHashSet;
import java.util.Set;

/** A visible EditText owns composition, selection and clipboard for one session.
 * Based on the 0.0.2b overlay; tokens and final snapshots bridge its UI thread to
 * the current launcher without restoring the historical launcher's rules.
 */
public final class NativeTextInputPlugin extends GodotPlugin {
    private static final String TAG = "RPGGodoNativeInput";
    public static final int MODE_TEXT = 0;
    public static final int MODE_NICKNAME = 1;
    public static final int MODE_URL = 2;
    public static final int MODE_PASSWORD = 3;
    public static final int MODE_MULTILINE = 4;
    public static final int MODE_CHAT = 5;
    public static final int MODE_NUMBER = 6;
    public static final int MODE_CONSOLE = 7;
    private static final SignalInfo CHAT = new SignalInfo("chat_checkpoint", String.class, String.class);
    private static final SignalInfo DISPLAY = new SignalInfo("display_changed", String.class);
    private static final SignalInfo SNAPSHOT = new SignalInfo("snapshot",
            String.class, String.class, Integer.class, Integer.class, Boolean.class);
    private static final SignalInfo CLOSED = new SignalInfo("closed",
            String.class, String.class, Integer.class, Integer.class, Boolean.class, String.class);

    private volatile Activity activity;
    private DisplayPreferences displayPreferences;
    // Lifecycle hooks and Back may arrive outside the Android UI thread.
    private volatile String token = "";
    private volatile boolean resumed = true;
    private String dismissKeyToken = "";
    private int dismissKeyCode;
    private FrameLayout overlay;
    private EditText editor;
    private boolean changingText;
    private boolean secret;
    private boolean sawIme;
    private int currentMode;
    private ChatEditJournal journal;
    private String beforeEdit = "";
    private boolean checkpointQueued;
    private boolean chatBusy;
    private boolean selectionMenuOpen;
    private ActionMode selectionMode;
    private static final int SPOILER_ACTION = 0x00f00401;
    private int lockedStart, lockedEnd;
    private String pendingChatFinish = "";

    public NativeTextInputPlugin(Godot godot) { super(godot); }

    @Override public String getPluginName() { return "NativeTextInput"; }

    @Override public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new LinkedHashSet<>();
        signals.add(SNAPSHOT);
        signals.add(CLOSED);
        signals.add(CHAT);
        signals.add(DISPLAY);
        return signals;
    }

    @Override public View onMainCreate(Activity currentActivity) {
        activity = currentActivity;
        overlay = new FrameLayout(currentActivity);
        overlay.setLayoutParams(new ViewGroup.LayoutParams(-1, -1));
        overlay.setVisibility(View.GONE);
        overlay.setClickable(true);
        overlay.setBackgroundColor(Color.TRANSPARENT);
        editor = new EditText(currentActivity) {
            @Override protected void onSelectionChanged(int start, int end) {
                super.onSelectionChanged(start, end);
                if (chatEditLocked() && (start != lockedStart || end != lockedEnd)) {
                    changingText = true;
                    setSelection(lockedStart, lockedEnd);
                    changingText = false;
                    return;
                }
                queueChatCheckpoint();
            }
            @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                if (token.isEmpty() || !resumed || overlay.getVisibility() != View.VISIBLE) return null;
                InputConnection target = super.onCreateInputConnection(info);
                if (target == null) return null;
                final String connectionToken = token;
                return new InputConnectionWrapper(target, false) {
                    private boolean retired() {
                        return !isInputConnectionCurrent(connectionToken, token, resumed
                                && overlay != null && overlay.getVisibility() == View.VISIBLE);
                    }
                    private boolean blocked() { return retired() || chatEditLocked(); }
                    @Override public boolean beginBatchEdit() {
                        return !blocked() && super.beginBatchEdit();
                    }
                    @Override public boolean performEditorAction(int action) {
                        return blocked() || super.performEditorAction(action);
                    }
                    @Override public boolean performPrivateCommand(String action, android.os.Bundle data) {
                        return blocked() || super.performPrivateCommand(action, data);
                    }
                    @Override public boolean commitText(CharSequence text, int cursor) {
                        return blocked() || super.commitText(text, cursor);
                    }
                    @Override public boolean setComposingText(CharSequence text, int cursor) {
                        return blocked() || super.setComposingText(text, cursor);
                    }
                    @Override public boolean commitText(CharSequence text, int cursor, android.view.inputmethod.TextAttribute attributes) {
                        return blocked() || super.commitText(text, cursor, attributes);
                    }
                    @Override public boolean setComposingText(CharSequence text, int cursor, android.view.inputmethod.TextAttribute attributes) {
                        return blocked() || super.setComposingText(text, cursor, attributes);
                    }
                    @Override public boolean setComposingRegion(int start, int end, android.view.inputmethod.TextAttribute attributes) {
                        if (blocked()) return true;
                        boolean result = super.setComposingRegion(start, end, attributes); queueChatCheckpoint(); return result;
                    }
                    @Override public boolean replaceText(int start, int end, CharSequence text, int cursor, android.view.inputmethod.TextAttribute attributes) {
                        return blocked() || super.replaceText(start, end, text, cursor, attributes);
                    }
                    @Override public boolean commitCompletion(android.view.inputmethod.CompletionInfo info) {
                        return blocked() || super.commitCompletion(info);
                    }
                    @Override public boolean commitCorrection(android.view.inputmethod.CorrectionInfo info) {
                        return blocked() || super.commitCorrection(info);
                    }
                    @Override public boolean deleteSurroundingText(int before, int after) {
                        return blocked() || super.deleteSurroundingText(before, after);
                    }
                    @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
                        return blocked() || super.deleteSurroundingTextInCodePoints(before, after);
                    }
                    @Override public boolean setSelection(int start, int end) {
                        return blocked() || super.setSelection(start, end);
                    }
                    @Override public boolean sendKeyEvent(KeyEvent event) {
                        if (retired()) return true;
                        return handleDismissKey(event.getKeyCode(), event) || chatEditLocked() || super.sendKeyEvent(event);
                    }
                    @Override public void closeConnection() {
                        if (!retired()) super.closeConnection();
                    }
                    @Override public boolean performContextMenuAction(int id) {
                        return blocked() || super.performContextMenuAction(id);
                    }
                    @Override public boolean finishComposingText() {
                        if (blocked()) return true;
                        boolean result = super.finishComposingText(); queueChatCheckpoint(); return result;
                    }
                    @Override public boolean endBatchEdit() {
                        if (retired()) return false;
                        boolean result = super.endBatchEdit(); queueChatCheckpoint(); return result;
                    }
                    @Override public boolean setComposingRegion(int start, int end) {
                        if (blocked()) return true;
                        boolean result = super.setComposingRegion(start, end); queueChatCheckpoint(); return result;
                    }
                };
            }
            @Override protected void onCreateContextMenu(ContextMenu menu) {
                super.onCreateContextMenu(menu);
                addSpoilerAction(menu, token, null);
            }
            @Override public boolean onTextContextMenuItem(int id) {
                if (chatEditLocked()) return true;
                if (currentMode == MODE_CHAT && (id == android.R.id.undo || id == android.R.id.redo)) {
                    chatCommand(id == android.R.id.undo ? "undo" : "redo"); return true;
                }
                return super.onTextContextMenuItem(id);
            }
            @Override public boolean onKeyDown(int keyCode, KeyEvent event) {
                if (handleDismissKey(keyCode, event)) return true;
                if (chatEditLocked() && keyCode != KeyEvent.KEYCODE_BACK) return true;
                if (currentMode == MODE_CHAT && event.isCtrlPressed()) {
                    if (keyCode == KeyEvent.KEYCODE_Z || keyCode == KeyEvent.KEYCODE_Y) {
                        chatCommand(keyCode == KeyEvent.KEYCODE_Y || event.isShiftPressed() ? "redo" : "undo");
                        return true;
                    }
                }
                return super.onKeyDown(keyCode, event);
            }
            @Override public boolean onKeyUp(int keyCode, KeyEvent event) {
                return handleDismissKey(keyCode, event) || super.onKeyUp(keyCode, event);
            }
            @Override public boolean onTouchEvent(MotionEvent event) {
                return chatEditLocked() || super.onTouchEvent(event);
            }
            @Override public boolean onKeyPreIme(int keyCode, KeyEvent event) {
                if (handleDismissKey(keyCode, event)) return true;
                return super.onKeyPreIme(keyCode, event);
            }
        };
        editor.setTextColor(Color.WHITE);
        editor.setHintTextColor(Color.rgb(180, 190, 205));
        editor.setTextSize(18);
        GradientDrawable editorBackground = new GradientDrawable();
        editorBackground.setColor(Color.rgb(20, 28, 45));
        editorBackground.setCornerRadius(dp(4));
        editorBackground.setStroke(dp(1), Color.rgb(211, 223, 225));
        editor.setBackground(editorBackground);
        editor.setPadding(dp(12), dp(6), dp(12), dp(6));
        editor.setSelectAllOnFocus(false);
        editor.setLongClickable(true);
        FrameLayout.LayoutParams editorParams = new FrameLayout.LayoutParams(-1, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP);
        editorParams.setMargins(dp(12), dp(8), dp(12), 0);
        overlay.addView(editor, editorParams);
        editor.setCustomSelectionActionModeCallback(new ActionMode.Callback() {
            @Override public boolean onCreateActionMode(ActionMode mode, Menu menu) {
                mode.setTag(token);
                selectionMode = mode;
                selectionMenuOpen = true;
                addSpoilerAction(menu, token, mode);
                return true;
            }
            @Override public boolean onPrepareActionMode(ActionMode mode, Menu menu) {
                addSpoilerAction(menu, (String) mode.getTag(), mode);
                return true;
            }
            @Override public boolean onActionItemClicked(ActionMode mode, MenuItem item) {
                if (item.getItemId() != SPOILER_ACTION) return false;
                if (token.equals(mode.getTag())) chatCommand("spoiler");
                mode.finish();
                return true;
            }
            @Override public void onDestroyActionMode(ActionMode mode) {
                if (selectionMode != mode) return;
                selectionMode = null;
                selectionMenuOpen = false;
                queueChatCheckpoint();
            }
        });
        editor.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {
                beforeEdit = s.toString();
            }
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                if (!changingText && !chatEditLocked() && journal != null && currentMode == MODE_CHAT)
                    journal.replace(beforeEdit, start, before, s.subSequence(start, start + count).toString());
            }
            @Override public void afterTextChanged(Editable text) {
                if (!changingText) snapshot();
            }
        });
        editor.setOnEditorActionListener((view, actionId, event) -> {
            if (currentMode != MODE_MULTILINE && event != null
                    && (event.getKeyCode() == KeyEvent.KEYCODE_ENTER || event.getKeyCode() == KeyEvent.KEYCODE_NUMPAD_ENTER)) {
                int action = consoleEnterAction(event.getAction(), event.getRepeatCount(), composing());
                if (action < 0) return false; // Let the IME confirm its candidate first.
                if (action > 0) finish(token, currentMode == MODE_CHAT ? "send" : "done");
                return true;
            }
            if (actionId == EditorInfo.IME_ACTION_DONE || actionId == EditorInfo.IME_ACTION_GO
                    || actionId == EditorInfo.IME_ACTION_SEND) {
                finish(token, currentMode == MODE_CHAT ? "send" : "done");
                return true;
            }
            return false; // Multiline Enter inserts a newline, never confirms the Host popup.
        });
        overlay.setOnTouchListener((view, event) -> {
            if (currentMode != MODE_CHAT && event.getActionMasked() == MotionEvent.ACTION_DOWN) finish(token, "blur");
            return true; // Chat is completed by Back/IME; never activate a Godot control underneath.
        });
        overlay.setOnApplyWindowInsetsListener((view, insets) -> {
            boolean imeVisible = insets.isVisible(WindowInsets.Type.ime());
            String current = token;
            if (!current.isEmpty() && sawIme && !imeVisible && !selectionMenuOpen && editor.hasWindowFocus()) {
                view.post(() -> finish(current, "ime_hidden"));
            }
            sawIme = imeVisible && !current.isEmpty();
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                    | WindowInsets.Type.displayCutout());
            overlay.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        Log.i(TAG, "NativeTextInput ready");
        return overlay;
    }

    @Override public boolean shouldBeOnTop() { return true; }

    @UsedByGodot public void openInput(String requested, String text, String hint,
            int maxCodePoints, int mode, int selectionStart, int selectionEnd, boolean masked) {
        onUi(requested, () -> {
            if (requested.isEmpty() || requested.equals(token)) return;
            if (editor == null || overlay == null) {
                emitSignal(CLOSED, requested, "", 0, 0, true, "unavailable");
                return;
            }
            finish(token, "switch");
            token = requested;
            currentMode = mode;
            journal = mode == MODE_CHAT ? new ChatEditJournal() : null;
            chatBusy = false;
            selectionMenuOpen = false;
            pendingChatFinish = "";
            editor.setEnabled(true);
            editor.setFocusableInTouchMode(true);
            changingText = true;
            sawIme = false;
            editor.setHint(hint);
            int type = InputType.TYPE_CLASS_TEXT;
            if (mode == MODE_URL) type |= InputType.TYPE_TEXT_VARIATION_URI;
            if (mode == MODE_NICKNAME) type |= InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            if (mode == MODE_PASSWORD) type |= InputType.TYPE_TEXT_VARIATION_PASSWORD;
            if (mode == MODE_NUMBER) type = InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL;
            boolean multiline = mode == MODE_MULTILINE;
            if (multiline) type |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
            editor.setInputType(type);
            // Visual wrapping is independent of the field's IME/newline rules.
            editor.setSingleLine(false);
            editor.setRawInputType(type);
            editor.setHorizontallyScrolling(false);
            editor.setMinLines(1);
            editor.setMaxLines(4);
            ViewGroup.LayoutParams params = editor.getLayoutParams();
            params.height = ViewGroup.LayoutParams.WRAP_CONTENT;
            editor.setLayoutParams(params);
            editor.setGravity(Gravity.TOP | Gravity.START);
            editor.setImeOptions((multiline ? EditorInfo.IME_ACTION_NONE : mode == MODE_CHAT ? EditorInfo.IME_ACTION_SEND : EditorInfo.IME_ACTION_DONE)
                    | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN
                    | (mode == MODE_PASSWORD ? EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING : 0));
            InputFilter singleLine = new SingleLineFilter(
                    () -> changingText || currentMode == MODE_MULTILINE || chatEditLocked());
            editor.setFilters(mode == MODE_NICKNAME
                    ? new InputFilter[]{singleLine, new AsciiNicknameFilter(maxCodePoints)}
                    : maxCodePoints > 0 ? new InputFilter[]{singleLine, new CodePointLengthFilter(maxCodePoints)}
                    : new InputFilter[]{singleLine});
            if (mode == MODE_CHAT) {
                // Preserve the selected destination, including spans, for edits from
                // hardware/clipboard/autofill paths outside InputConnection.
                editor.setFilters(new InputFilter[]{new ChatCommandFilter(this::chatEditLocked), singleLine});
            }
            setSecret(mode == MODE_PASSWORD && masked);
            editor.setText(text);
            String value = editor.getText().toString();
            // Godot columns count Unicode code points; Android selection uses UTF-16.
            int start = toUtf16Offset(value, selectionStart);
            int end = toUtf16Offset(value, selectionEnd);
            editor.setSelection(start, end);
            if (journal != null) journal.accept(0, selectionStart, selectionEnd);
            changingText = false;
            overlay.setVisibility(View.VISIBLE);
            overlay.bringToFront();
            editor.requestFocus();
            editor.post(() -> {
                if (!requested.equals(token)) return;
                InputMethodManager ime = ime();
                if (ime != null) ime.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT);
            });
        });
    }

    @UsedByGodot public void closeInput(String requested, boolean discard) {
        onUi(requested, () -> finish(requested, discard ? "discard" : "close"));
    }

    @Override public void onMainPause() {
        resumed = false;
        String current = token;
        onUi(current, () -> finish(current, "pause"));
    }

    private DisplayPreferences displayPreferences() {
        if (displayPreferences == null && activity != null && getGodot().getRenderView() != null) {
            displayPreferences = new DisplayPreferences(activity, getGodot().getRenderView().getView(),
                state -> emitSignal(DISPLAY.getName(), state));
        }
        return displayPreferences;
    }

    @UsedByGodot public void setDisplayOrientation(int mode) {
        Activity current = activity;
        if (current != null) current.runOnUiThread(() -> {
            DisplayPreferences display = displayPreferences();
            if (display != null) display.setOrientation(mode);
        });
    }

    @UsedByGodot public void requestDisplayState() {
        Activity current = activity;
        if (current != null) current.runOnUiThread(() -> {
            DisplayPreferences display = displayPreferences();
            if (display != null) display.requestState();
        });
    }

    @Override public void onMainResume() {
        resumed = true;
        // The initial Activity resume can precede Godot's plugin registration.
        // GDScript creates the listener when ready; later resumes refresh it.
        if (displayPreferences != null) displayPreferences.requestState();
    }

    @Override public boolean onMainBackPressed() {
        String current = token;
        if (current.isEmpty()) return false;
        onUi(current, () -> finish(current, "back"));
        return true;
    }

    @Override public void onMainDestroy() {
        resumed = false;
        if (displayPreferences != null) displayPreferences.destroy();
        displayPreferences = null;
        finish(token, "destroy");
        activity = null;
        overlay = null;
        editor = null;
    }

    private void setSecret(boolean value) {
        secret = value;
        editor.setTransformationMethod(value ? PasswordTransformationMethod.getInstance() : null);
    }

    private int selection(int offset) {
        String text = editor.getText().toString();
        return toCodePointOffset(text, offset);
    }

    static int toUtf16Offset(String text, int offset) {
        return text.offsetByCodePoints(0, Math.max(0, Math.min(offset, text.codePointCount(0, text.length()))));
    }

    static int toCodePointOffset(String text, int offset) {
        int clamped = Math.max(0, Math.min(offset, text.length()));
        // A native caret should be on a code-point boundary; clamp a split surrogate backward.
        if (clamped > 0 && clamped < text.length() && Character.isHighSurrogate(text.charAt(clamped - 1))
                && Character.isLowSurrogate(text.charAt(clamped))) clamped--;
        return text.codePointCount(0, clamped);
    }

    private void snapshot() {
        if (token.isEmpty() || changingText) return;
        if (currentMode == MODE_CHAT) { queueChatCheckpoint(); return; }
        emitSignal(SNAPSHOT, token, editor.getText().toString(),
                selection(editor.getSelectionStart()), selection(editor.getSelectionEnd()), secret);
    }

    static boolean isInputConnectionCurrent(String connectionToken, String activeToken, boolean visible) {
        return visible && !connectionToken.isEmpty() && connectionToken.equals(activeToken);
    }

    private boolean handleDismissKey(int keyCode, KeyEvent event) {
        if (keyCode != KeyEvent.KEYCODE_ESCAPE && keyCode != KeyEvent.KEYCODE_BACK) return false;
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (token.isEmpty()) return !dismissKeyToken.isEmpty() && dismissKeyCode == keyCode;
            if (event.getRepeatCount() == 0) {
                dismissKeyToken = token;
                dismissKeyCode = keyCode;
            }
            return true;
        }
        if (event.getAction() != KeyEvent.ACTION_UP || dismissKeyCode != keyCode || dismissKeyToken.isEmpty()) return false;
        String requested = dismissKeyToken;
        dismissKeyToken = "";
        // Match the key-down's session; a late release cannot close a new editor.
        finish(requested, keyCode == KeyEvent.KEYCODE_ESCAPE ? "escape" : "back");
        return true;
    }

    private void dismissEditor(boolean restoreFocus) {
        sawIme = false;
        InputMethodManager manager = ime();
        if (editor != null) {
            BaseInputConnection.removeComposingSpans(editor.getText());
            if (manager != null) manager.hideSoftInputFromWindow(editor.getWindowToken(), 0);
            editor.clearFocus();
            // Prevent Android from immediately choosing the hidden EditText again.
            editor.setFocusable(false);
        }
        if (overlay != null) overlay.setVisibility(View.GONE);
        if (restoreFocus && resumed && activity != null && activity.hasWindowFocus()
                && getGodot().getRenderView() != null) {
            getGodot().getRenderView().getView().requestFocus();
        }
        // onCreateInputConnection now returns null for the retired session.
        if (manager != null && editor != null) manager.restartInput(editor);
    }

    private void finish(String requested, String reason) {
        if (requested.isEmpty() || !requested.equals(token)) return;
        if (chatBusy && !reason.equals("discard") && !reason.equals("destroy")) {
            // Finish only after the semantic command projection is acknowledged.
            // Otherwise Back/IME hide would replay the pre-command draft as final.
            if (pendingChatFinish.isEmpty()) pendingChatFinish = reason;
            return;
        }
        if (currentMode == MODE_CHAT && !reason.equals("discard") && !reason.equals("destroy")) {
            BaseInputConnection.removeComposingSpans(editor.getText());
            emitChatCheckpoint(reason, true);
        }
        String text = editor.getText().toString();
        int start = selection(editor.getSelectionStart()), end = selection(editor.getSelectionEnd());
        token = "";
        chatBusy = false;
        selectionMenuOpen = false;
        pendingChatFinish = "";
        changingText = true;
        dismissEditor(!reason.equals("pause") && !reason.equals("destroy") && !reason.equals("switch"));
        changingText = false;
        emitSignal(CLOSED, requested, text, start, end, secret, reason);
    }

    // -1: IME owns composition; 0: consume release/repeat; 1: complete once.
    static int consoleEnterAction(int action, int repeats, boolean composing) {
        if (composing) return -1;
        return action == KeyEvent.ACTION_DOWN && repeats == 0 ? 1 : 0;
    }

    private boolean composing() {
        return editor != null && BaseInputConnection.getComposingSpanStart(editor.getText()) >= 0;
    }

    private void queueChatCheckpoint() {
        if (changingText || currentMode != MODE_CHAT || journal == null || token.isEmpty()
                || checkpointQueued || chatBusy) return;
        checkpointQueued = true;
        String requested = token;
        editor.post(() -> {
            checkpointQueued = false;
            if (!requested.equals(token) || changingText || chatBusy || composing()) return;
            journal.select(selection(editor.getSelectionStart()), selection(editor.getSelectionEnd()));
            if (journal.sequence == journal.baseline) return;
            emitChatCheckpoint("edit", false);
            journal.boundary();
        });
    }

    private void addSpoilerAction(Menu menu, String requested, ActionMode mode) {
        menu.removeItem(SPOILER_ACTION);
        if (currentMode != MODE_CHAT || token.isEmpty() || !requested.equals(token)
                || editor.getSelectionStart() == editor.getSelectionEnd()) return;
        menu.add(Menu.NONE, SPOILER_ACTION, Menu.NONE, "标记为剧透")
                .setEnabled(!chatBusy)
                .setOnMenuItemClickListener(item -> {
                    if (requested.equals(token)) chatCommand("spoiler");
                    if (mode != null) mode.finish();
                    return true;
                });
    }

    private void chatCommand(String command) {
        if (token.isEmpty() || currentMode != MODE_CHAT || chatBusy) return;
        lockChatSelection();
        BaseInputConnection.removeComposingSpans(editor.getText());
        journal.sequence++;
        chatBusy = true;
        emitChatCheckpoint(command, false);
    }

    private boolean chatEditLocked() {
        return !changingText && currentMode == MODE_CHAT && chatBusy;
    }

    private void lockChatSelection() {
        lockedStart = Math.max(0, editor.getSelectionStart());
        lockedEnd = Math.max(0, editor.getSelectionEnd());
    }

    private void emitChatCheckpoint(String action, boolean last) {
        if (journal == null || token.isEmpty()) return;
        journal.select(selection(editor.getSelectionStart()), selection(editor.getSelectionEnd()));
        try {
            JSONArray edits = new JSONArray();
            for (ChatEditJournal.Edit edit : journal.edits) {
                edits.put(new JSONObject().put("a", edit.start).put("b", edit.end)
                        .put("text", edit.text).put("group", edit.group));
            }
            JSONObject data = new JSONObject().put("base", journal.baseline).put("seq", journal.sequence)
                    .put("edits", edits).put("text", editor.getText().toString())
                    .put("start", journal.selectionStart).put("end", journal.selectionEnd)
                    .put("action", action).put("final", last);
            emitSignal(CHAT, token, data.toString());
        } catch (JSONException error) { throw new IllegalStateException(error); }
    }

    @UsedByGodot public void acceptChat(String requested, String projection) {
        onUi(requested, () -> {
            if (!requested.equals(token) || currentMode != MODE_CHAT || journal == null) return;
            try {
                JSONObject data = new JSONObject(projection);
                int seq = data.getInt("seq");
                if (!journal.canAccept(data.getInt("base"), seq, composing())) return;
                changingText = true;
                String value = data.getString("text");
                if (!editor.getText().toString().equals(value)) editor.setText(value);
                int start = data.getInt("start"), end = data.getInt("end");
                editor.setSelection(toUtf16Offset(value, start), toUtf16Offset(value, end));
                journal.accept(seq, start, end);
                changingText = false;
                chatBusy = false;
                lockedStart = editor.getSelectionStart();
                lockedEnd = editor.getSelectionEnd();
                String message = data.optString("message", "");
                if (!message.isEmpty()) android.widget.Toast.makeText(activity, message, android.widget.Toast.LENGTH_SHORT).show();
                String reason = pendingChatFinish;
                pendingChatFinish = "";
                if (!reason.isEmpty()) finish(requested, reason);
            } catch (JSONException error) { throw new IllegalStateException(error); }
        });
    }

    private InputMethodManager ime() {
        Activity current = activity;
        return current == null ? null : (InputMethodManager) current.getSystemService(Context.INPUT_METHOD_SERVICE);
    }

    private void onUi(String requested, Runnable action) {
        Activity current = activity;
        if (current == null) {
            if (!requested.isEmpty()) emitSignal(CLOSED, requested, "", 0, 0, true, "unavailable");
            return;
        }
        current.runOnUiThread(() -> {
            try {
                action.run();
            } catch (RuntimeException error) {
                Log.e(TAG, "Native input failed", error);
                String failed = token.isEmpty() ? requested : token;
                token = "";
                changingText = true;
                try {
                    chatBusy = false;
                    pendingChatFinish = "";
                    selectionMenuOpen = false;
                    dismissEditor(true);
                } catch (RuntimeException cleanupError) {
                    Log.e(TAG, "Native input cleanup failed", cleanupError);
                } finally {
                    changingText = false;
                }
                if (!failed.isEmpty()) emitSignal(CLOSED, failed, "", 0, 0, true, "error");
            }
        });
    }

    @UsedByGodot public float uiDp(float value) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
                activity.getResources().getDisplayMetrics());
    }

    @UsedByGodot public float uiSp(float value) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value,
                activity.getResources().getDisplayMetrics());
    }

    private int dp(int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }

    static final class SingleLineFilter implements InputFilter {
        private final java.util.function.BooleanSupplier bypass;
        SingleLineFilter(java.util.function.BooleanSupplier bypass) { this.bypass = bypass; }
        @Override public CharSequence filter(CharSequence source, int start, int end,
                Spanned dest, int dstart, int dend) {
            if (bypass.getAsBoolean()) return null;
            boolean hasNewline = false;
            for (int i = start; i < end; i++) {
                if (source.charAt(i) == '\r' || source.charAt(i) == '\n') { hasNewline = true; break; }
            }
            if (!hasNewline) return null;
            // Preserve IME/clipboard spans when removing real line breaks.
            if (source instanceof Spanned) {
                SpannableStringBuilder result = new SpannableStringBuilder(source, start, end);
                for (int i = result.length() - 1; i >= 0; i--) {
                    if (result.charAt(i) == '\r' || result.charAt(i) == '\n') result.delete(i, i + 1);
                }
                return result;
            }
            StringBuilder result = new StringBuilder();
            for (int i = start; i < end; i++) {
                char c = source.charAt(i);
                if (c != '\r' && c != '\n') result.append(c);
            }
            return result.toString();
        }
    }

    static final class ChatCommandFilter implements InputFilter {
        private final java.util.function.BooleanSupplier locked;
        ChatCommandFilter(java.util.function.BooleanSupplier locked) { this.locked = locked; }
        @Override public CharSequence filter(CharSequence source, int start, int end,
                Spanned dest, int dstart, int dend) {
            // Returning an empty string would still delete a selected range.
            // Keep the replaced text and spans until the command is acknowledged.
            return locked.getAsBoolean() ? dest.subSequence(dstart, dend) : null;
        }
    }

    static final class CodePointLengthFilter implements InputFilter {
        private final int maximum;
        CodePointLengthFilter(int maximum) { this.maximum = maximum; }
        @Override public CharSequence filter(CharSequence source, int start, int end,
                Spanned dest, int dstart, int dend) {
            String retained = dest.subSequence(0, dstart).toString() + dest.subSequence(dend, dest.length());
            int available = maximum - retained.codePointCount(0, retained.length());
            if (available <= 0) return "";
            String inserted = source.subSequence(start, end).toString();
            if (inserted.codePointCount(0, inserted.length()) <= available) return null;
            // Preserve composing spans when only the length has to be trimmed.
            return source.subSequence(start, start + inserted.offsetByCodePoints(0, available));
        }
    }

    static final class AsciiNicknameFilter implements InputFilter {
        private final int maximum;
        AsciiNicknameFilter(int maximum) { this.maximum = maximum; }
        @Override public CharSequence filter(CharSequence source, int start, int end,
                Spanned dest, int dstart, int dend) {
            int available = maximum - dest.length() + dend - dstart;
            StringBuilder result = new StringBuilder();
            for (int i = start; i < end && result.length() < available; i++) {
                char c = source.charAt(i);
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) result.append(c);
            }
            return source.subSequence(start, end).toString().contentEquals(result) ? null : result.toString();
        }
    }
}
