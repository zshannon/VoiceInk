//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test @MainActor
    func forkBundleDisablesLicenseEnforcement() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ZCSLicenseEnforcementDisabled") as? Bool == true)
        #expect(LicenseViewModel.shared.licenseState == .licensed)
        #expect(LicenseViewModel.shared.hasVerifiedLicense)
    }

    @Test @MainActor
    func forkBuildDisablesLicenseEnforcement() {
        let viewModel = LicenseViewModel(licenseEnforcementDisabled: true)

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.hasVerifiedLicense)
        #expect(viewModel.usageRestrictionMessage == nil)

        #expect(viewModel.startTrial())

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.usageRestrictionMessage == nil)

        viewModel.refreshLicenseState()

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.usageRestrictionMessage == nil)
    }

}
