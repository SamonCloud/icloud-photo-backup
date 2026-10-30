import Foundation

func requiresNetwork(_ error: Error) -> Bool {
    let value = error as NSError
    return value.domain == "PHPhotosErrorDomain" && value.code == 3164
}

// A network retry is limited to Apple's explicit network-required error.
// Other failures retain their original cause instead of triggering downloads.
func exportWithFallback(allowNetwork: Bool, shouldStop: () -> Bool,
                        attempt: (Bool) -> Error?) -> Error? {
    guard let error = attempt(false) else { return nil }
    guard requiresNetwork(error), allowNetwork, !shouldStop() else { return error }
    return attempt(true)
}
