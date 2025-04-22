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

class MouseManager {

    // 添加共享单例实例
    static let shared = MouseManager()
    
    let mouserMapper = MouseMapper()
    
    var isRelativeMouseControlEnabled: Bool = false
    var accumulatedDeltaX = 0
    var accumulatedDeltaY = 0
    var recordCount = 0
    var dragging = false
    var skipMoveBack = false
    
    // 控制鼠标循环的变量
    private var isMouseLoopRunning = false
    
    init() {
    }
    
    func handleAbsoluteMouseAction(x: Int, y: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00) {
        mouserMapper.handleAbsoluteMouseAction(x: x, y: y, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
    }
    
    func handleRelativeMouseAction(dx: Int, dy: Int, mouseEvent: UInt8 = 0x00, wheelMovement: UInt8 = 0x00, dragged:Bool = false) {
        accumulatedDeltaX += dx
        accumulatedDeltaY += dy
        if self.skipMoveBack && recordCount > 0{
            if Logger.shared.MouseEventPrint {  Logger.shared.log(content: "Mouse event Skipped...") }
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            skipMoveBack = false
            return
        }
        
        // When mouse left up, relative will go back to prevous location, should avoid it
        if self.dragging && !dragged {
            skipMoveBack = true
            recordCount = 0
            if Logger.shared.MouseEventPrint {  Logger.shared.log(content: "Reset mouse move counter..") }
            mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)
        }
        self.dragging = dragged

        if Logger.shared.MouseEventPrint {  Logger.shared.log(content: "Handled handleRelativeMouseAction, delta: (\(accumulatedDeltaX), \(accumulatedDeltaY)), accumulated records count: \(recordCount)") }
        mouserMapper.handleRelativeMouseAction(dx: accumulatedDeltaX, dy: accumulatedDeltaY, mouseEvent: mouseEvent, wheelMovement: wheelMovement)

        // Reset the accumulated delta and the record count
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        recordCount = 0
    }
    
    func relativeMouse2TopLeft() {
        mouserMapper.relativeMouse2TopLeft()
    }

    func relativeMouse2BottomLeft() {
        mouserMapper.relativeMouse2BottomLeft()
    }

    func relativeMouse2TopRight() {
        mouserMapper.relativeMouse2TopRight()
    }
    
    func relativeMouse2BottomRight() {
        mouserMapper.relativeMouse2BottomRight()
    }
    
    func runMouseLoop() {
        // 如果已经在运行，不要重复启动
        guard !isMouseLoopRunning else {
            Logger.shared.log(content: "鼠标循环已经在运行中")
            return
        }
        
        isMouseLoopRunning = true
        Logger.shared.log(content: "鼠标循环开始运行")
        
        DispatchQueue.global().async {
            
            // 停止当前循环
            self.isMouseLoopRunning = false
            
            // 调用适当的循环函数
            if UserSettings.shared.MouseControl == .relative {
                self.isMouseLoopRunning = true
                DispatchQueue.global().async {
                    while self.isMouseLoopRunning {
                        // 相对模式移动
                        // 向上移动
                        self.handleRelativeMouseAction(dx: 0, dy: -50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // 向下移动
                        self.handleRelativeMouseAction(dx: 0, dy: 50)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // 向左移动
                        self.handleRelativeMouseAction(dx: -50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                        if !self.isMouseLoopRunning { break }
                        
                        // 向右移动
                        self.handleRelativeMouseAction(dx: 50, dy: 0)
                        Thread.sleep(forTimeInterval: 1.0)
                    }
                    
                    Logger.shared.log(content: "相对模式鼠标循环已停止")
                }
            } else {
                // 启动绝对模式的弹球循环
                self.runBouncingBallMouseLoop()
            }
        }
    }
    
    func stopMouseLoop() {
        isMouseLoopRunning = false
        Logger.shared.log(content: "请求停止鼠标循环")
    }
    
    // 运行弹球式鼠标运动
    func runBouncingBallMouseLoop() {
        // 如果已经在运行，不要重复启动
        guard !isMouseLoopRunning else {
            Logger.shared.log(content: "鼠标循环已经在运行中")
            return
        }
        
        isMouseLoopRunning = true
        Logger.shared.log(content: "弹球式鼠标循环开始运行")
        
        DispatchQueue.global().async {
            // 绝对定位模式的边界
            let maxX = 4096
            let maxY = 4096
            
            // 初始位置和运动参数
            var x = 50
            var y = 50
            var velocityX = 40
            var velocityY = 0
            let gravity = 5
            let energyLoss = 0.9 // 碰撞时的能量损失系数
            let framerate = 0.05 // 50ms每帧
            
            // 能量恢复参数
            let minEnergyThreshold = 15  // 垂直速度小于这个值时认为能量不足
            let boostVelocity = 500       // 提供的额外上升速度
            let horizontalBoost = 1000     // 提供的额外水平速度
            var lowEnergyCount = 0       // 低能量状态计数器
            var boostDirection = 1       // 水平提升方向 (1 或 -1)
            
            while self.isMouseLoopRunning {
                // 计算新位置
                x += velocityX
                velocityY += gravity
                y += velocityY
                
                // 检测能量状态
                _ = abs(velocityX) + abs(velocityY)
                let isLowEnergy = abs(velocityY) < minEnergyThreshold && y > maxY * Int(0.8)
                
                if isLowEnergy {
                    lowEnergyCount += 1
                } else {
                    lowEnergyCount = 0
                }
                
                // 如果连续多帧处于低能量状态，给予额外提升力
                if lowEnergyCount > 10 {
                    velocityY = -boostVelocity
                    boostDirection = (velocityX > 0) ? -1 : 1
                    velocityX = boostDirection * horizontalBoost
                    lowEnergyCount = 0
                    Logger.shared.log(content: "提供额外动力，垂直速度: \(velocityY), 水平速度: \(velocityX)")
                }
                
                // 检测碰撞
                if x <= 0 {
                    x = 0
                    velocityX = Int(Double(-velocityX) * energyLoss)
                } else if x >= maxX {
                    x = maxX
                    velocityX = Int(Double(-velocityX) * energyLoss)
                }
                
                if y <= 0 {
                    y = 0
                    velocityY = Int(Double(-velocityY) * energyLoss)
                } else if y >= maxY {
                    y = maxY
                    velocityY = Int(Double(-velocityY) * energyLoss)
                    
                    // 如果在底部碰撞后速度很低，给予额外的上升动力
                    if abs(velocityY) < minEnergyThreshold {
                        velocityY = -boostVelocity
                        // 同时给一个随机的水平推力，让运动更有变化
                        velocityX += Int.random(in: -15...15)
                        Logger.shared.log(content: "底部碰撞后提供额外动力，新垂直速度: \(velocityY)")
                    }
                }
                
                // 更新鼠标位置
                self.handleAbsoluteMouseAction(x: x, y: y)
                
                // 等待下一帧
                Thread.sleep(forTimeInterval: framerate)
                
                // 检查循环是否应该终止
                if !self.isMouseLoopRunning { break }
            }
            
            Logger.shared.log(content: "弹球式鼠标循环已停止")
        }
    }
}
