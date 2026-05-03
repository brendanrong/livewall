import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Apply the user's dock-icon preference. Default is .regular (dock visible);
// users can toggle this off in Settings → General → Show in dock.
app.setActivationPolicy(Preferences.shared.showDockIcon ? .regular : .accessory)
app.run()
