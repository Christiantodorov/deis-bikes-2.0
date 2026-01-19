//
//  ContentView.swift
//  deis bikes 2.0
//
//  Created by Christian Todorov on 1/14/26.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Models

enum DBAppUserStatus: String, Codable {
    case loggedOut
    case needsWaiver
    case needsMoodle
    case pendingApproval
    case activeRider
    case suspended
}

enum DBRideRentalType: String, CaseIterable, Identifiable, Codable {
    case commuter = "Commuter (18–24h max)"
    case regular  = "Regular (2–4h max)"
    var id: String { rawValue }
}

struct DBBike: Identifiable, Codable, Equatable {
    let id: String              // "DeisBike #3"
    var isAvailable: Bool
    var lockBatteryPercent: Int
    var conditionNote: String
}

enum DBRentalState: String, Codable {
    case none
    case assigned
    case checklistComplete
    case chainUnlocked
    case chainSecuredConfirmed
    case wheelUnlocked
    case inRide
    case ending
    case completed
}

struct DBRental: Codable {
    var type: DBRideRentalType
    var bikeId: String
    var start: Date
    var due: Date
    var remainingSeconds: Int
    var state: DBRentalState

    // “SDK verified” flags (mocked)
    var chainPhysicallySecuredVerified: Bool
}

struct DBChatMessage: Identifiable, Codable {
    let id: UUID
    let sender: Sender
    let text: String
    let timestamp: Date

    enum Sender: String, Codable {
        case user
        case admin
    }

    enum CodingKeys: String, CodingKey {
        case id, sender, text, timestamp
    }

    init(id: UUID = UUID(), sender: Sender, text: String, timestamp: Date) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.sender = try container.decode(Sender.self, forKey: .sender)
        self.text = try container.decode(String.self, forKey: .text)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sender, forKey: .sender)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

// MARK: - App State

final class DBAppState: ObservableObject {
    // User
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var rememberMe: Bool = true

    @Published var status: DBAppUserStatus = .loggedOut

    // Waiver/Moodle
    @Published var waiverAccepted: Bool = false
    @Published var moodleCompleted: Bool = false

    // Admin (for demo; in real life this is a separate admin tool)
    @Published var adminNotifiedUserReady: Bool = false
    @Published var adminHasVerifiedMoodle: Bool = false

    // Bikes
    @Published var bikes: [DBBike] = [
        DBBike(id: "DeisBike #1", isAvailable: true,  lockBatteryPercent: 72, conditionNote: "Good"),
        DBBike(id: "DeisBike #2", isAvailable: true,  lockBatteryPercent: 35, conditionNote: "Rear reflector loose"),
        DBBike(id: "DeisBike #3", isAvailable: true,  lockBatteryPercent: 92, conditionNote: "Excellent"),
        DBBike(id: "DeisBike #4", isAvailable: false, lockBatteryPercent: 18, conditionNote: "In use"),
        DBBike(id: "DeisBike #5", isAvailable: true,  lockBatteryPercent: 55, conditionNote: "Seat squeaks")
    ]

    // Rental Flow
    @Published var selectedRentalType: DBRideRentalType? = nil
    @Published var assignedBike: DBBike? = nil
    @Published var rental: DBRental? = nil

    @Published var checklistTiresOK: Bool = false
    @Published var checklistSeatAdjusted: Bool = false
    @Published var checklistHelmet: Bool = false
    @Published var checklistLightsOK: Bool = false
    @Published var requestDifferentBikeReason: String = ""

    @Published var userConfirmedChainSecuredInBasket: Bool = false

    // Chat
    @Published var chatMessages: [DBChatMessage] = [
        DBChatMessage(sender: .admin, text: "Welcome to DeisBikes Support. How can we help?", timestamp: Date())
    ]
    @Published var chatDraft: String = ""

    // Errors / Alerts
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""
    @Published var showAlert: Bool = false

    // Timer
    private var timer: Timer?

    // MARK: Login / Onboarding

    func signUpOrLogin() {
        // INTEGRATION: Replace with Google Sign-In + Brandeis domain restriction + 2FA flow.
        // For now, we simulate:
        guard email.lowercased().hasSuffix("@brandeis.edu") else {
            showError("Invalid email", "Please use your brandeis.edu account.")
            return
        }
        if password.count < 4 {
            showError("Weak password", "Use at least 4 characters (demo).")
            return
        }

        // First time: needs waiver
        if status == .loggedOut {
            status = .needsWaiver
        }
    }

    func acceptWaiver() {
        waiverAccepted = true
        status = .needsMoodle

        // Notify admin user is ready (mock)
        adminNotifiedUserReady = true
        // INTEGRATION: Send notification to admins (e.g., Firestore flag + Cloud Function).
    }

    func markMoodleCompletedByUser() {
        moodleCompleted = true
        status = .pendingApproval
        // INTEGRATION: Store “user claims Moodle completed” and ask admin to verify.
    }

    func adminApproveActiveRider() {
        guard waiverAccepted else {
            showError("Cannot approve", "Waiver not accepted.")
            return
        }
        guard moodleCompleted else {
            showError("Cannot approve", "User has not marked Moodle as completed.")
            return
        }
        adminHasVerifiedMoodle = true
        status = .activeRider

        // INTEGRATION: push notification to user.
        showInfo("Approved", "You are ready to ride DeisBikes. Open the app to begin riding!")
    }

    // MARK: Active Rider / Rental

    var availableCount: Int {
        bikes.filter { $0.isAvailable }.count
    }

    func beginUnlockFlow(type: DBRideRentalType) {
        guard status == .activeRider else {
            showError("Not allowed", "You must be an Active Rider to rent a bike.")
            return
        }
        guard rental == nil else {
            showError("One bike per ride", "You already have an active rental.")
            return
        }

        selectedRentalType = type

        // Assign bike with highest battery among available
        let candidates = bikes.filter { $0.isAvailable }
        guard let best = candidates.max(by: { $0.lockBatteryPercent < $1.lockBatteryPercent }) else {
            showError("No bikes available", "Please try again later.")
            return
        }

        assignedBike = best

        // Create rental with due time (use the max values for demo)
        let now = Date()
        let maxHours: Int = (type == .commuter) ? 24 : 4
        let due = Calendar.current.date(byAdding: .hour, value: maxHours, to: now) ?? now.addingTimeInterval(TimeInterval(maxHours * 3600))
        rental = DBRental(
            type: type,
            bikeId: best.id,
            start: now,
            due: due,
            remainingSeconds: maxHours * 3600,
            state: .assigned,
            chainPhysicallySecuredVerified: false
        )

        // Mark bike unavailable
        setBikeAvailability(best.id, isAvailable: false)

        // Reset checklist
        checklistTiresOK = false
        checklistSeatAdjusted = false
        checklistHelmet = false
        checklistLightsOK = false
        requestDifferentBikeReason = ""
        userConfirmedChainSecuredInBasket = false
    }

    func requestDifferentBike() {
        guard let current = assignedBike else { return }
        let others = bikes.filter { $0.isAvailable && $0.id != current.id }
        guard let bestAlt = others.max(by: { $0.lockBatteryPercent < $1.lockBatteryPercent }) else {
            showError("No alternate bikes", "No other bikes are currently available.")
            return
        }

        // Put current bike back as available (since user rejected it)
        setBikeAvailability(current.id, isAvailable: true)

        // Assign new bike, mark unavailable
        assignedBike = bestAlt
        setBikeAvailability(bestAlt.id, isAvailable: false)

        // Update rental
        if var r = rental {
            r.bikeId = bestAlt.id
            r.state = .assigned
            rental = r
        }

        showInfo("New bike assigned", "Assigned \(bestAlt.id). Reason logged (demo): \(requestDifferentBikeReason.isEmpty ? "—" : requestDifferentBikeReason)")
        requestDifferentBikeReason = ""
    }

    func completeChecklist() {
        guard checklistTiresOK && checklistSeatAdjusted && checklistHelmet && checklistLightsOK else {
            showError("Checklist incomplete", "Please confirm all safety checks to continue.")
            return
        }
        updateRentalState(.checklistComplete)
    }

    func unlockChain() {
        guard rental?.state == .checklistComplete else {
            showError("Not ready", "Complete the checklist first.")
            return
        }

        // INTEGRATION: call TetherSense SDK to unlock chain.
        updateRentalState(.chainUnlocked)
    }

    func confirmChainSecuredInBasketOrBag() {
        guard rental?.state == .chainUnlocked else {
            showError("Not ready", "Unlock the chain first.")
            return
        }
        guard userConfirmedChainSecuredInBasket else {
            showError("Confirm required", "Please confirm you secured the chain before continuing.")
            return
        }
        updateRentalState(.chainSecuredConfirmed)
    }

    func unlockRearWheel() {
        guard rental?.state == .chainSecuredConfirmed else {
            showError("Not ready", "Confirm chain secured first.")
            return
        }
        // INTEGRATION: call lock SDK to unlock rear wheel.
        updateRentalState(.wheelUnlocked)
        startRide()
    }

    func startRide() {
        updateRentalState(.inRide)
        startTimer()
    }

    func toggleWheelLockDuringRide() {
        guard rental?.state == .inRide else { return }
        // INTEGRATION: call lock SDK to lock/unlock rear wheel.
        showInfo("Wheel lock toggled", "Demo action. In real app, this calls the lock SDK.")
    }

    func attemptEndRide() {
        guard let r = rental, r.state == .inRide else { return }
        updateRentalState(.ending)

        // INTEGRATION: query SDK for “chain secured to correct slot” verification.
        // Demo: require the “verified” toggle in the End Ride screen.
    }

    func finalizeEndRideIfVerified() {
        guard var r = rental else { return }
        guard r.state == .ending else { return }
        guard r.chainPhysicallySecuredVerified else {
            showError("Cannot end ride", "Chain is not verified as secured to the correct bike slot.")
            // Return to ride state for user
            updateRentalState(.inRide)
            return
        }

        // INTEGRATION: lock rear wheel + secure chain
        stopTimer()

        // Make bike available again
        setBikeAvailability(r.bikeId, isAvailable: true)

        r.state = .completed
        rental = nil
        assignedBike = nil
        selectedRentalType = nil
        showInfo("Ride ended", "Thanks for riding DeisBikes.")
    }

    func cancelRentalIfNotInRide() {
        guard let r = rental else { return }
        if r.state == .inRide || r.state == .ending {
            showError("Cannot cancel", "You can only end the ride from Ride Mode.")
            return
        }

        // Return bike to available
        setBikeAvailability(r.bikeId, isAvailable: true)

        rental = nil
        assignedBike = nil
        selectedRentalType = nil
        showInfo("Canceled", "Rental canceled before ride started.")
    }

    // MARK: Chat

    func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        chatMessages.append(DBChatMessage(sender: .user, text: text, timestamp: Date()))
        chatDraft = ""

        // Demo auto-reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.chatMessages.append(DBChatMessage(sender: .admin, text: "Got it. We’ll take a look and follow up.", timestamp: Date()))
        }

        // INTEGRATION: send to backend (Firestore) and receive real-time updates.
    }

    // MARK: Helpers

    func setBikeAvailability(_ bikeId: String, isAvailable: Bool) {
        if let idx = bikes.firstIndex(where: { $0.id == bikeId }) {
            bikes[idx].isAvailable = isAvailable
        }
    }

    func updateRentalState(_ newState: DBRentalState) {
        if var r = rental {
            r.state = newState
            rental = r
        }
    }

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard var r = self.rental else { return }
            if r.state != .inRide { return }
            r.remainingSeconds = max(0, r.remainingSeconds - 1)
            self.rental = r

            if r.remainingSeconds == 0 {
                self.showError("Time expired", "Your rental time has ended. Please return to the shelter immediately.")
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func showError(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    func showInfo(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    func resetAll() {
        stopTimer()
        status = .loggedOut
        email = ""
        password = ""
        rememberMe = true
        waiverAccepted = false
        moodleCompleted = false
        adminNotifiedUserReady = false
        adminHasVerifiedMoodle = false
        rental = nil
        assignedBike = nil
        selectedRentalType = nil
        checklistTiresOK = false
        checklistSeatAdjusted = false
        checklistHelmet = false
        checklistLightsOK = false
        requestDifferentBikeReason = ""
        userConfirmedChainSecuredInBasket = false

        // Reset bikes
        bikes = [
            DBBike(id: "DeisBike #1", isAvailable: true,  lockBatteryPercent: 72, conditionNote: "Good"),
            DBBike(id: "DeisBike #2", isAvailable: true,  lockBatteryPercent: 35, conditionNote: "Rear reflector loose"),
            DBBike(id: "DeisBike #3", isAvailable: true,  lockBatteryPercent: 92, conditionNote: "Excellent"),
            DBBike(id: "DeisBike #4", isAvailable: false, lockBatteryPercent: 18, conditionNote: "In use"),
            DBBike(id: "DeisBike #5", isAvailable: true,  lockBatteryPercent: 55, conditionNote: "Seat squeaks")
        ]
    }
}

// MARK: - Location (basic)

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 42.3662, longitude: -71.2587), // Brandeis-ish
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        region.center = loc.coordinate
    }
}

// MARK: - App Entry

@main
struct DeisBikesApp: App {
    @StateObject private var appState = DBAppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Root Router

struct RootView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        NavigationStack {
            switch app.status {
            case .loggedOut:
                LoginView()
            case .needsWaiver:
                WaiverView()
            case .needsMoodle:
                MoodleView()
            case .pendingApproval:
                PendingApprovalView()
            case .activeRider:
                ActiveRiderHomeView()
            case .suspended:
                SuspendedView()
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(red: 0.05, green: 0.12, blue: 0.30), for: .navigationBar)
        .alert(app.alertTitle, isPresented: $app.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(app.alertMessage)
        }
    }
}

// MARK: - Screens

struct LoginView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(spacing: 16) {
            Text("DeisBikes")
                .font(.largeTitle.bold())

            Text("Login with your Brandeis account")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("email@brandeis.edu", text: $app.email)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password (demo)", text: $app.password)
                    .textFieldStyle(.roundedBorder)

                Toggle("Remember me", isOn: $app.rememberMe)
            }

            Button {
                app.signUpOrLogin()
            } label: {
                Text("Sign up / Login")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            VStack(spacing: 6) {
                Text("Demo note:")
                    .font(.subheadline.bold())
                Text("This screen simulates Google + 2FA. In the real app, replace with Google Sign-In restricted to @brandeis.edu and an email code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .navigationTitle("Login")
    }
}

struct WaiverView: View {
    @EnvironmentObject var app: DBAppState
    @State private var scrolledToBottom = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Waiver & Safety Agreement")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("BLANK WAIVER PLACEHOLDER")
                        .font(.headline)

                    Text("""
                    Replace this with the real waiver text once drafted.

                    • Safety agreement
                    • Penalties for not returning the bike
                    • Penalties for losing or damaging the bike
                    • Rider responsibilities (helmet, lights, etc.)

                    (Demo) Scroll to the bottom to enable “I Agree”.
                    """)

                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(.tertiary)

                    Text("End of waiver.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)

                    // A simple “bottom detector”
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { scrolledToBottom = true }
                    }
                    .frame(height: 1)
                }
                .padding()
            }
            .frame(maxHeight: 360)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                app.acceptWaiver()
            } label: {
                Text("I Agree")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!scrolledToBottom)

            Text("After waiver + Moodle course, you can expect approval within 24 hours.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
        .navigationTitle("Waiver")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { app.resetAll() }
            }
        }
    }
}

struct MoodleView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Moodle Bike Safety Course")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text("You cannot rent a bike until:")
                    .font(.headline)
                Text("1) You accept the waiver ✅")
                Text("2) You complete the Moodle safety course")
                Text("3) An admin verifies completion and approves you")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                // INTEGRATION: open Moodle URL
                app.showInfo("Moodle link", "Demo: open your Moodle course link here.")
            } label: {
                Text("Open Moodle Course")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                app.markMoodleCompletedByUser()
            } label: {
                Text("I Completed the Course")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
        .navigationTitle("Moodle")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { app.resetAll() }
            }
        }
    }
}

struct PendingApprovalView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Pending Approval")
                .font(.title2.bold())

            Text("An admin must verify your Moodle completion.\nExpected within 24 hours.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Text("Admin Console (Demo)")
                    .font(.headline)
                Text("This block simulates the Fleetview/admin approval flow.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: app.adminNotifiedUserReady ? "bell.fill" : "bell")
                    Text(app.adminNotifiedUserReady ? "Admin notified: user ready" : "Admin not notified yet")
                }

                Toggle("Admin verifies Moodle complete", isOn: $app.adminHasVerifiedMoodle)
                    .onChange(of: app.adminHasVerifiedMoodle) { _, newValue in
                        if newValue {
                            // Keep consistent: in a real system this is based on admin verification, not user toggle
                            app.adminHasVerifiedMoodle = true
                        }
                    }

                Button {
                    // For demo: treat user completion as required
                    app.adminApproveActiveRider()
                } label: {
                    Text("Approve as Active Rider")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding()
        .navigationTitle("Approval")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { app.resetAll() }
            }
        }
    }
}

struct SuspendedView: View {
    @EnvironmentObject var app: DBAppState
    var body: some View {
        VStack(spacing: 12) {
            Text("Account on Hold")
                .font(.title.bold())
            Text("Please contact DeisBikes admin support.")
                .foregroundStyle(.secondary)

            Button("Reset (Demo)") { app.resetAll() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

// MARK: - Active Rider Home + Flow

struct ActiveRiderHomeView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        ZStack {
            // Dark blue background
            Color(red: 0.05, green: 0.10, blue: 0.25)
                .ignoresSafeArea()

            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Available Bikes")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(app.availableCount) available right now")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                Section {
                    RideRentalTypeRow(type: .commuter)
                    RideRentalTypeRow(type: .regular)
                } header: {
                    Text("Choose a Rental Type")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    if let r = app.rental {
                        NavigationLink {
                            RentalFlowView()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(r.bikeId) • \(r.type.rawValue)")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("State: \(r.state.rawValue)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("No active rental")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Current Rental")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        ChatView()
                    } label: {
                        Text("Chat with Admin")
                            .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Support")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Reset App (Demo)") { app.resetAll() }
                        .foregroundStyle(Color.red.opacity(0.9))
                } header: {
                    Text("Demo Controls")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden) // Hide default list background
            .background(Color(red: 0.05, green: 0.12, blue: 0.30))
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("DeisBikes")
                    .foregroundColor(.white)
                    .font(.headline)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(red: 0.05, green: 0.12, blue: 0.30), for: .navigationBar)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func RideRentalTypeRow(type: DBRideRentalType) -> some View {
        let available = app.availableCount
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(type.rawValue)
                    .font(.headline)
                Text("Available: \(available)")
                    .foregroundStyle(.secondary)
                Text(type == .commuter ? "1 user per bike per ride. 18–24 hours max." : "1 user per bike per ride. 2–4 hours max.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unlock") {
                app.beginUnlockFlow(type: type)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.rental != nil || available == 0)
        }
        .padding(.vertical, 6)
    }
}

struct RentalFlowView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(spacing: 12) {
            if let bike = app.assignedBike, let r = app.rental {
                BikeDetailsCard(bike: bike, rental: r)

                switch r.state {
                case .assigned:
                    PreRideChecklistView()
                case .checklistComplete:
                    UnlockChainView()
                case .chainUnlocked:
                    ChainSecuredConfirmView()
                case .chainSecuredConfirmed:
                    UnlockWheelView()
                case .wheelUnlocked, .inRide:
                    RideModeView()
                case .ending:
                    EndRideView()
                case .completed:
                    Text("Completed")
                case .none:
                    Text("No rental")
                }

                Spacer(minLength: 8)

                if r.state != .inRide && r.state != .ending {
                    Button(role: .destructive) {
                        app.cancelRentalIfNotInRide()
                    } label: {
                        Text("Cancel Rental (before ride)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

            } else {
                Text("No rental in progress.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Rental")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BikeDetailsCard: View {
    let bike: DBBike
    let rental: DBRental

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(bike.id)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack {
                Label("Battery \(bike.lockBatteryPercent)%", systemImage: "battery.100")
                Spacer()
                Label("Condition: \(bike.conditionNote)", systemImage: "wrench.and.screwdriver")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("Rental: \(rental.type.rawValue)")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text("Reminder: carry the TetherSense chain in the basket or your bag.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct PreRideChecklistView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pre-Ride Checklist")
                .font(.headline)
                .foregroundStyle(.primary)

            Toggle("Tire pressure (not flat)", isOn: $app.checklistTiresOK)
            Toggle("Adjust seat height", isOn: $app.checklistSeatAdjusted)
            Toggle("Wear a helmet", isOn: $app.checklistHelmet)
            Toggle("Lights are working", isOn: $app.checklistLightsOK)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Need a different bike?")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                TextField("Optional reason (e.g., seat issue)", text: $app.requestDifferentBikeReason)
                    .textFieldStyle(.roundedBorder)

                Button("Assign a Different Bike") {
                    app.requestDifferentBike()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Button {
                app.completeChecklist()
            } label: {
                Text("Continue to Unlock Chain")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct UnlockChainView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock TetherSense Chain")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("This unlocks the chain so you can place it in the basket or your bag.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                app.unlockChain()
            } label: {
                Text("Unlock Chain (Demo)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct ChainSecuredConfirmView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Secure the Chain")
                .font(.headline)
                .foregroundStyle(.primary)

            Toggle("I safely secured the chain in the basket/bag", isOn: $app.userConfirmedChainSecuredInBasket)
                .foregroundStyle(.secondary)

            Button {
                app.confirmChainSecuredInBasketOrBag()
            } label: {
                Text("Continue to Unlock Rear Wheel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct UnlockWheelView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unlock Rear Wheel")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("After this, Ride Mode begins.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                app.unlockRearWheel()
            } label: {
                Text("Unlock Rear Wheel (Demo)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

struct RideModeView: View {
    @EnvironmentObject var app: DBAppState
    @StateObject private var location = LocationManager()

    // Massell Pond bike shelter (approx; adjust to exact location)
    private let shelterCoord = CLLocationCoordinate2D(latitude: 42.3671, longitude: -71.2581)

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ride Mode")
                    .font(.headline)
                    .foregroundStyle(.primary)

                if let r = app.rental {
                    Text("Remaining time: \(formatTime(r.remainingSeconds))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Map(coordinateRegion: $location.region, annotationItems: [ShelterPin(coordinate: shelterCoord)]) { item in
                MapMarker(coordinate: item.coordinate)
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .onAppear {
                location.request()
            }

            HStack(spacing: 12) {
                Button {
                    app.toggleWheelLockDuringRide()
                } label: {
                    Text("Lock/Unlock Wheel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    app.attemptEndRide()
                } label: {
                    Text("Lock (End Ride)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    struct ShelterPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }
}

struct EndRideView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("End Ride")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Secure the TetherSense chain to the correct bike slot in the Massell Bike Shelter. The ride cannot end until verified.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("SDK Verified: chain secured to correct slot (Demo)", isOn: bindingForChainVerification)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                app.finalizeEndRideIfVerified()
            } label: {
                Text("Confirm & End Ride")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    private var bindingForChainVerification: Binding<Bool> {
        Binding(
            get: { app.rental?.chainPhysicallySecuredVerified ?? false },
            set: { newValue in
                if var r = app.rental {
                    r.chainPhysicallySecuredVerified = newValue
                    app.rental = r
                }
            }
        )
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var app: DBAppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.chatMessages) { msg in
                            ChatBubble(msg: msg)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: app.chatMessages.count) { _, _ in
                    if let last = app.chatMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Message admin…", text: $app.chatDraft)
                    .textFieldStyle(.roundedBorder)

                Button("Send") {
                    app.sendChat()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatBubble: View {
    let msg: DBChatMessage

    var isUser: Bool { msg.sender == .user }

    var body: some View {
        HStack {
            if isUser { Spacer() }

            VStack(alignment: .leading, spacing: 4) {
                Text(msg.sender == .user ? "You" : "Admin")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(msg.text)
                    .padding(10)
                    .background(isUser ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(msg.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)

            if !isUser { Spacer() }
        }
    }
}

