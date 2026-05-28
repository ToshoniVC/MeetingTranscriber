Product Requirements Document (PRD): Jot Menu Bar App

To: macOS Developer / Engineering
From: Product Owner
Date: May 27, 2026 (2:25 PM CEST)
Subject: Development of "Jot" - A Customizable macOS Menu Bar Transcription Utility

1. Executive Summary

Objective: Develop a lightweight, native macOS application that resides in the Menu Bar, monitors a local folder for meeting audio files, and automatically transcribes them using a customizable OpenAI-compatible audio API endpoint (e.g., Groq, OpenAI, or local Whisper servers).
Context & Constraints:

The user records 10+ meetings daily. To preserve native macOS audio functionality (AirPods auto-switching, keyboard volume controls), audio capture is handled externally by Audio Hijack.

This application ("Jot") serves strictly as the background watcher, API orchestrator, and file manager.

The app provides transcription only (no LLM summarization) and must allow the user to define their own transcription endpoint, model, and API key.

The app must be highly reliable, survive reboots, and require zero daily maintenance from the user.

2. System Architecture & Tech Stack

Language/Framework: Swift & SwiftUI (Highly recommended over Python wrappers to ensure minimal battery drain, native UI/UX, and seamless integration with macOS FSEvents).

Deployment: Standalone .app bundle.

External Dependency: Audio Hijack (handles the actual .mp3 creation) and Apple Shortcuts.

APIs:

Transcription: Any OpenAI-compatible /audio/transcriptions endpoint (Configurable by user).

3. User Interface (UI) Requirements

3.1 The Menu Bar Icon (State Management)

The app operates primarily from the Menu Bar, but does not use a dropdown menu. Clicking the Menu Bar icon directly toggles the visibility of the Main Application Window.
It must visually communicate its current state:

Idle State: Standard, monochromatic icon (e.g., a simple microphone or text icon matching the macOS system theme).

Processing State: Subtle animation (e.g., a spinning sync wheel or pulsing dot) indicating that an API call is currently active.

Error State: The icon turns red or displays an exclamation mark.

3.2 The Main Application Window

Clicking the Menu Bar icon opens a native SwiftUI window featuring a standard macOS Left Navigation Sidebar. The sidebar contains the following three tabs:

Tab 1: Transcripts (Default View)

A native file browser view linked directly to the user-defined "Output Folder".

Displays a list/grid of processed meeting folders (each containing the matched audio and text transcript).

Double-clicking a folder reveals its contents. Double-clicking a file opens it in the Mac's default application.

Includes basic file management (Right-click to delete, reveal in Finder, or rename).

Tab 2: Audit Log

A diagnostic view to track the application's background automation.

Displays a chronological list of events with timestamps.

Successes: "Transcribed '2026-05-27_14-24_Client_Call.mp3' successfully (1m 24s)."

Errors: Clearly highlights failures (e.g., "[API Timeout] Failed to process 'Sync.mp3'").

Should include a "Retry" button next to failed items to manually re-trigger the API pipeline for that file.

Includes a "Clear Log" button.

Tab 3: Settings

The configuration center for the application. It must securely store the following user inputs (using macOS Keychain for API keys):

API Configuration:

API Base URL: Text field (e.g., https://api.groq.com/openai/v1/audio/transcriptions).

Model String: Text field (e.g., whisper-large-v3 or whisper-1).

API Key: Secure text field (macOS Keychain integrated).

Folder Configuration:

Watch Folder: (Folder picker - where Audio Hijack saves the .mp3).

Output Folder: (Folder picker - where the final organized meeting folders are saved and what populates the "Transcripts" tab).

System & Automation:

Recording Shortcut: A global hotkey recorder field (e.g., Cmd + Shift + R). When triggered, Jot will execute the predefined Apple Shortcut/AppleScript to ask for a meeting name and start Audio Hijack.

Launch on Startup: Checkbox to add the app to macOS Login Items.

Quit Jot: Button to fully exit the background daemon.

4. Core Functional Requirements

4.1 Folder Monitoring

The app must utilize native macOS FSEvents (or DispatchSourceFileSystemObject) to monitor the designated "Watch Folder" with zero polling overhead.

It must correctly detect when a new audio file (.mp3, .m4a, .wav) has finished writing (to avoid trying to upload an incomplete file while Audio Hijack is still recording).

4.2 The API Pipeline & File Management

When a completed audio file is detected:

Change State: Update Menu Bar icon to "Processing" and log event in Audit Log.

Audio Transcription: Send the audio file as multipart form data to the user-defined API Base URL.

Include the user-defined Model String in the payload.

Authenticate using the user-defined API Key (Bearer token).

Set response format to extract raw text.

Handle timeouts or file size limits gracefully.

File Generation & Organization:

Create a new subfolder inside the user-defined "Output Folder". Name this folder identically to the original audio file (e.g., 2026-05-27_14-24_Client_Call).

Save the resulting raw transcript text to this new subfolder as a .txt or .md file.

Move the original audio file from the "Watch Folder" into this new subfolder.

Ensure no residual data (audio files or temporary files) remains in the "Watch Folder".

Reset State: Return Menu Bar icon to "Idle" and log success in Audit Log.

4.3 Error Handling

If the internet drops, an API key is invalid, or the custom endpoint is down, the app must NOT crash.

It must change the Menu Bar icon to the "Error" state.

It must log the specific API error code/message in the Audit Log tab.

Failed audio files must remain in the "Watch Folder" until successfully processed or manually deleted.

5. Expected User Workflow (The "Happy Path")

Setup: User installs the app, clicks the icon to open the window, navigates to Settings, inputs their desired API URL/Model/Key, selects their folders, configures their Recording Shortcut, and checks "Launch on Startup".

Recording: User triggers their configured global shortcut (e.g., Cmd + Shift + R). Jot intercepts this, asking for a meeting name and triggering Audio Hijack to start recording.

Meeting Ends: User stops the recording. Audio Hijack saves the timestamped audio file (e.g., 2026-05-27_14-24_Client_Call.mp3) to the Watch Folder.

Automation: Jot detects the file. The menu bar icon starts spinning. The audio is routed to the custom API.

Result: The icon stops spinning. The user clicks the Menu Bar icon, and the main window opens directly to the Transcripts tab. Here, a new folder named 2026-05-27_14-24_Client_Call has been created, containing both the original .mp3 recording and the final .txt transcript. The initial Watch Folder is left completely empty, ready for the next meeting.