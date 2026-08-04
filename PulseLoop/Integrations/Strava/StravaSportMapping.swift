import Foundation

/// Maps PulseLoop activity types to Strava's TCX `Sport` attribute and API `sport_type` values.
enum StravaSportMapping {
    /// The TCX v2 schema only allows "Running" | "Biking" | "Other" for the Activity Sport attribute.
    static func tcxSport(for type: String) -> String {
        switch canonical(type) {
        case "run": return "Running"
        case "cycle": return "Biking"
        default: return "Other"
        }
    }

    /// Desired Strava `sport_type` for the activity-update call after upload.
    static func sportType(for type: String) -> String {
        switch canonical(type) {
        case "run": return "Run"
        case "walk": return "Walk"
        case "cycle": return "Ride"
        case "gym": return "WeightTraining"
        case "squash": return "Squash"
        case "yoga": return "Yoga"
        case "hike": return "Hike"
        default: return "Workout" // sport, dance, other, and any unknown custom type
        }
    }

    /// True when uploading the TCX sport alone won't yield the desired `sport_type`, so the
    /// uploader must follow up with an activity update. Only run and cycle map losslessly.
    static func needsSportTypeFix(for type: String) -> Bool {
        let resolved = canonical(type)
        return resolved != "run" && resolved != "cycle"
    }

    /// Resolves legacy aliases (outdoor_run, ride, cycling, strength) via ActivityMeta rather
    /// than duplicating its alias table.
    private static func canonical(_ type: String) -> String {
        ActivityMeta.meta(type).type
    }
}
