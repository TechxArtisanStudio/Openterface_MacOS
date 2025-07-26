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

/// Simple dependency injection container for managing service instances
class DependencyContainer {
    static let shared = DependencyContainer()
    
    private var services: [String: Any] = [:]
    private let queue = DispatchQueue(label: "com.openterface.dependency-container", attributes: .concurrent)
    
    private init() {
        // Simple initialization without circular dependencies
    }
    
    /// Register a service instance for a given protocol type
    func register<T>(_ type: T.Type, instance: T) {
        let key = String(describing: type)
        queue.async(flags: .barrier) {
            self.services[key] = instance
        }
    }
    
    /// Register a factory closure for lazy instantiation
    func register<T>(_ type: T.Type, factory: @escaping () -> T) {
        let key = String(describing: type)
        queue.async(flags: .barrier) {
            self.services[key] = factory
        }
    }
    
    /// Resolve a service instance for a given protocol type
    func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: type)
        
        return queue.sync {
            if let factory = services[key] as? () -> T {
                // If it's a factory, call it and replace with the instance
                let instance = factory()
                services[key] = instance
                return instance
            } else if let instance = services[key] as? T {
                return instance
            } else {
                // Provide fallback for LoggerProtocol to break circular dependencies
                if type == LoggerProtocol.self {
                    let loggerInstance = Logger.shared as! T
                    services[key] = loggerInstance
                    return loggerInstance
                }
                fatalError("Service of type \(type) not registered. Please register it before use.")
            }
        }
    }
    
    /// Check if a service is registered
    func isRegistered<T>(_ type: T.Type) -> Bool {
        let key = String(describing: type)
        return queue.sync {
            return services[key] != nil
        }
    }
    
    /// Remove a registered service
    func unregister<T>(_ type: T.Type) {
        let key = String(describing: type)
        queue.async(flags: .barrier) {
            self.services.removeValue(forKey: key)
        }
    }
    
    /// Clear all registered services
    func clearAll() {
        queue.async(flags: .barrier) {
            self.services.removeAll()
        }
    }
}
