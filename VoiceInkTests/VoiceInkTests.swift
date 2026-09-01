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
    func forkBuildDisablesLicenseEnforcement() {
        let viewModel = LicenseViewModel(licenseEnforcementDisabled: true)

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.usageRestrictionMessage == nil)

        viewModel.startTrial()

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.usageRestrictionMessage == nil)

        viewModel.refreshLicenseState()

        #expect(viewModel.licenseState == .licensed)
        #expect(viewModel.canUseApp)
        #expect(viewModel.usageRestrictionMessage == nil)
    }

}
