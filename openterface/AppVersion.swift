/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import Foundation

struct AppVersion {
    /// Gets the app version string in format "MARKETING_VERSION(BUILD_NUMBER)"
    /// For example: "1.20(60)"
    static func getVersionString() -> String {
        let bundle = Bundle.main
        let marketingVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        
        return "\(marketingVersion)(\(buildNumber))"
    }
    
    /// Gets just the marketing version (e.g., "1.20")
    static func getMarketingVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    /// Gets just the build number (e.g., "60")
    static func getBuildNumber() -> String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
