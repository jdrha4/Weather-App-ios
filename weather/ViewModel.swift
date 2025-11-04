import Foundation
import SwiftUI

struct WeatherResponse: Codable {
    let name: String
    let weather: [Weather]
    let main: Main
    let wind: Wind
}

struct Weather: Codable, Hashable {
    let main: String
    let description: String
    let icon: String
}

struct Main: Codable {
    let temp: Double
    let humidity: Int
    let feels_like: Double
}

struct Wind: Codable {
    let speed: Double
}

// MARK: - Geocoding models

struct GeoLocation: Codable, Identifiable, Hashable {
    // Use lat/lon as the stable identity (OpenWeather geocoding has no id)
    // Include country/state/name in the computed id to reduce collision risk,
    // but we will still dedupe in code before publishing.
    var id: String { "\(name)|\(state ?? "")|\(country)|\(lat)|\(lon)" }
    let name: String
    let local_names: [String: String]?
    let lat: Double
    let lon: Double
    let country: String
    let state: String?
}

@MainActor
class ViewModel: ObservableObject {
    @Published var apidata: WeatherResponse?
    @Published var suggestions: [GeoLocation] = []
    
    private let apiKey = "36547996c19f0d809fc730fad1950406"
    private var searchTask: Task<Void, Never>?
    
    // MARK: - Weather fetching by city name
    
    func fetch(city: String = "prague") {
        guard let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(
                string: "https://api.openweathermap.org/data/2.5/weather?q=\(encoded)&appid=\(apiKey)&units=metric"
              )
        else { return }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let result = try JSONDecoder().decode(WeatherResponse.self, from: data)
                self.apidata = result
            } catch {
                print("Decoding failed:", error)
            }
        }
    }
    
    // MARK: - Weather fetching by coordinates (preferred after selection)
    
    func fetchWeather(lat: Double, lon: Double) {
        guard let url = URL(
            string: "https://api.openweathermap.org/data/2.5/weather?lat=\(lat)&lon=\(lon)&appid=\(apiKey)&units=metric"
        ) else { return }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let result = try JSONDecoder().decode(WeatherResponse.self, from: data)
                self.apidata = result
            } catch {
                print("Decoding failed:", error)
            }
        }
    }
    
    // MARK: - City search (Geocoding) with debounce + validation + de-duplication
    
    func searchCities(query: String) {
        // Cancel any in-flight search task (debounce)
        searchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            self.suggestions = []
            return
        }
        
        searchTask = Task { [weak self] in
            // Debounce delay
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            
            guard let self = self, !Task.isCancelled else { return }
            
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://api.openweathermap.org/geo/1.0/direct?q=\(encoded)&limit=5&appid=\(self.apiKey)")
            else {
                await MainActor.run { self.suggestions = [] }
                return
            }
            
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let rawResults = try JSONDecoder().decode([GeoLocation].self, from: data)
                
                // 1) Sanitize text fields (trim, remove control chars)
                let sanitized = rawResults.map { sanitize($0) }
                
                // 2) Validate entries (non-empty name/country, lat/lon in range, not (0,0), 2-letter country)
                let valid = sanitized.filter { isValid($0) }
                
                // 3) Deduplicate by (lat, lon) preserving order
                var seenCoords = Set<String>()
                var unique: [GeoLocation] = []
                unique.reserveCapacity(valid.count)
                
                for item in valid {
                    let key = coordKey(item.lat, item.lon)
                    if !seenCoords.contains(key) {
                        seenCoords.insert(key)
                        unique.append(item)
                    }
                }
                
                // 4) Limit to 5
                let results = Array(unique.prefix(5))
                
                await MainActor.run {
                    self.suggestions = results
                }
            } catch {
                await MainActor.run {
                    self.suggestions = []
                }
                print("Geocoding failed:", error)
            }
        }
    }
    
    // MARK: - Utilities
    
    func cancelSuggestions() {
        searchTask?.cancel()
        suggestions = []
    }
    
    // MARK: - Selection handler
    
    func selectSuggestion(_ location: GeoLocation) {
        fetchWeather(lat: location.lat, lon: location.lon)
        cancelSuggestions()
    }
}

// MARK: - Validation / Sanitization helpers

private func isValid(_ loc: GeoLocation) -> Bool {
    // Basic required fields
    let name = loc.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let country = loc.country.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !country.isEmpty else { return false }
    
    // Country should be ISO alpha-2 (OpenWeather returns that)
    guard country.count == 2 else { return false }
    
    // Coordinate sanity
    guard (-90.0...90.0).contains(loc.lat),
          (-180.0...180.0).contains(loc.lon) else { return false }
    
    // Exclude the degenerate (0,0) coordinate (often bogus)
    guard !(loc.lat == 0 && loc.lon == 0) else { return false }
    
    return true
}

private func sanitize(_ loc: GeoLocation) -> GeoLocation {
    func clean(_ s: String) -> String {
        // Remove control characters and trim whitespace/newlines
        let filtered = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    let cleanName = clean(loc.name)
    let cleanCountry = clean(loc.country)
    let cleanState = loc.state.map { clean($0) }
    
    // Recreate a sanitized GeoLocation (local_names left as-is)
    return GeoLocation(
        name: cleanName,
        local_names: loc.local_names,
        lat: loc.lat,
        lon: loc.lon,
        country: cleanCountry,
        state: cleanState
    )
}

private func coordKey(_ lat: Double, _ lon: Double) -> String {
    "\(lat.rounded(toPlaces: 6)),\(lon.rounded(toPlaces: 6))"
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        guard places >= 0 else { return self }
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
