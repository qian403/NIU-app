# Moodle feature architecture

The Moodle feature is split into four boundaries so UI changes do not need to
know about tokens, WebKit cookies, or endpoint details.

1. `MoodleService` owns transport, authentication, token persistence, and the
   low-level Moodle Web Service/HTML operations.
2. `MoodleAPIClientProtocol` is the replaceable API boundary used by data
   repositories.
3. Repositories convert transport responses into feature data and decide on
   compatibility fallbacks.
4. View models own screen state; SwiftUI views only render state and send user
   intents back to their view model.

The course-detail shell only owns the selected tab. Announcements, assignments,
resources, attendance, and grades each keep an independent view model and
focused repository. Their state is retained by the shell, so switching tabs
does not repeat completed network requests.

## Attendance

Attendance is intentionally isolated in `Attendance/` because it has two data
paths. `MoodleAttendanceRepository` first calls the installation-provided
`mod_attendance_get_user_sessions` service. It only uses the HTML path when the
server does not expose usable per-user status data. Neither the view nor its
view model should call HTML parsing directly.

When adding an attendance field, map it into `MoodleAttendanceRecord` in the
repository. Do not expose Web Service or HTML response types to the view.

## Adding an endpoint

1. Add the low-level call to `MoodleService`.
2. Add only the required method to `MoodleAPIClientProtocol`.
3. Expose feature-specific data through the appropriate repository protocol.
4. Inject the repository into the view model. Avoid new `MoodleService.shared`
   calls in view models and views.

Authentication tokens, autologin keys, and attendance QR secrets must never be
logged or included in user-facing diagnostics.
