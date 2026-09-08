# simpleRDP 1.3

## Multiple sessions in one window

- Open independent connection tabs with **+** or **⌘T**.
- Switching tabs keeps other connections running. Closing an active tab asks for
  confirmation and disconnects only that session. Closing the window or quitting
  disconnects all sessions; shutdown waits for session/download workers.
- Keyboard focus and held keys are released when leaving a desktop.

## Destination-first remote file downloads

- Copy files remotely with Ctrl+C, a context menu, or an application menu. A
  non-blocking **Download Remote Files…** toolbar button appears in that tab.
- Choose a destination before file contents are requested. Files download into a
  private hidden `.simpleRDP-download-<UUID>` directory in the selected folder,
  then move into place with collision-safe names. No application clipboard cache
  is created, and downloaded file URLs never replace the Mac clipboard.
- Progress, Cancel, Dismiss, and Show Download in Finder are available. Downloads
  remain with their originating session when switching tabs.
- Clipboard changes/disconnection cancel unfinished transfers. Normal cancellation
  removes partial files; final move failures preserve completed files and report
  their recovery location. Once local finalization begins it finishes even if the
  session closes, preventing a half-cancelled save.
- A forced quit or crash may leave a hidden partial directory in the selected
  destination. It can be removed manually (Finder **⌘⇧.** shows hidden files).
  The app does not scan users’ folders or keep a persistent destination registry.

## Clipboard ownership

- Remote text automatically copies to the Mac clipboard **from the selected tab**,
  with no prompt. Background tabs and late replies cannot overwrite it. Switching
  tabs does not replay a previous remote text copy.
- A single Mac clipboard monitor routes a new local copy to the selected connected
  tab while the app is active. Clipboard changes observed while the app is inactive
  wait until the app is active. Mac files stream from their original locations;
  no duplicate local cache is needed. Paste remotely with Ctrl+V.
- Switching tabs does not send stale Mac contents to another machine. To paste the
  same local items into a second session, copy them again on the Mac first.
- Remote text is not echoed into another session. Local clipboard snapshots stay
  associated with the session that advertised them. New local copies wait while
  that selected session is downloading remote files.
- Local file clipboard still supports regular files, not folders. Remote downloads
  support validated folder hierarchies. Image/rich-text clipboard formats are not
  added in this release. Server clipboard/file-redirection support is required.

## Validation

Automated regression tests cover ownership/late text replies, local routing,
lazy offers, stale destination-sheet acceptance, streamed destination downloads,
cancellation cleanup, independent tab lifecycle, and existing safety behavior.
Live Windows/xrdp interoperability and visual testing remain manual release checks.