//
//  ResetFactoryView.swift
//  openterface
//
//  Created by Shawn on 2025/2/25.
//

import SwiftUI

struct ResetFactoryView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var isResetting = false
    @State private var isCompleted = false
    @State private var currentStep = 0
    @State private var isHovering = false
    @State private var stepMessages = [
        "准备开始恢复出厂设置...",
        "1. 打开串口",
        "2. 开始恢复出厂设置",
        "3. 启用 RTS",
        "4. 等待中...",
        "5. 禁用 RTS",
        "6. 等待中...",
        "7. 关闭串口",
        "8. 重新打开串口",
        "恢复出厂设置完成！"
    ]
    
    // 用于自动滚动的ID
    @Namespace private var bottomID
    
    var body: some View {
        ZStack {
            // 背景
            colorScheme == .dark ? Color.black : Color.white
            
            VStack(alignment: .center, spacing: 30) {
                Spacer()
                    .frame(height: 20)
                
                // 图标
                Image(systemName: isCompleted ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 60))
                    .foregroundColor(isCompleted ? .green : .blue)
                    .opacity(0.9)
                    .padding(.bottom, 10)
                
                // 标题
                Text(isCompleted ? "恢复出厂设置完成" : "恢复出厂设置")
                    .font(.system(size: 24, weight: .medium))
                    .padding(.bottom, 5)
                
                // 说明文字
                if !isCompleted && !isResetting {
                    Text("此操作将会将设备恢复到出厂状态")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 20)
                }
                
                // 当前步骤显示
                if isResetting || isCompleted {
                    // 进度条
                    ProgressView(value: Double(currentStep), total: Double(stepMessages.count - 1))
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(width: 280)
                        .padding(.bottom, 15)
                    
                    // 步骤列表
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(0..<min(currentStep + 1, stepMessages.count), id: \.self) { index in
                                    HStack(spacing: 12) {
                                        // 步骤状态图标
                                        ZStack {
                                            Circle()
                                                .fill(index == currentStep && !isCompleted ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
                                                .frame(width: 26, height: 26)
                                            
                                            if index == currentStep && !isCompleted {
                                                if isResetting {
                                                    Image(systemName: "arrow.triangle.2.circlepath")
                                                        .font(.system(size: 12))
                                                        .foregroundColor(.blue)
                                                        .rotationEffect(.degrees(isResetting ? 360 : 0))
                                                        .animation(Animation.linear(duration: 2).repeatForever(autoreverses: false), value: isResetting)
                                                } else {
                                                    ProgressView()
                                                        .scaleEffect(0.6)
                                                }
                                            } else {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(.green)
                                            }
                                        }
                                        
                                        // 步骤文字
                                        Text(stepMessages[index])
                                            .font(.system(size: 14))
                                            .foregroundColor(index == currentStep && !isCompleted ? .primary : .secondary)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(index == currentStep && !isCompleted ? Color.blue.opacity(0.08) : Color.clear)
                                    )
                                    .id(index) // 为每个步骤设置ID
                                    
                                    // 为最后一个步骤添加底部ID标记
                                    if index == currentStep {
                                        Color.clear
                                            .frame(height: 1)
                                            .id(bottomID)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                        .frame(width: 320, height: 180)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .onChange(of: currentStep) { _ in
                            // 当步骤变化时，自动滚动到底部
                            withAnimation {
                                scrollProxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                
                // 完成后的额外指导
                if isCompleted {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("后续操作指南")
                            .font(.system(size: 16, weight: .medium))
                            .padding(.bottom, 5)
                        
                        ForEach(["1. 请关闭软件", "2. 断开硬件连接", "3. 等待3秒", "4. 重新连接硬件", "5. 重启软件"], id: \.self) { step in
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 14))
                                Text(step)
                                    .font(.system(size: 15))
                            }
                        }
                    }
                    .padding(.vertical, 15)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green.opacity(0.1))
                    )
                    .padding(.bottom, 20)
                }
                
                // 按钮
                Button(action: {
                    if isCompleted {
                        // 重置状态
                        isCompleted = false
                        isResetting = false
                        currentStep = 0
                    } else {
                        resetFactory()
                    }
                }) {
                    Text(isCompleted ? "返回" : (isResetting ? "正在恢复中..." : "开始恢复出厂设置"))
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 220, height: 46)
                        .background(isCompleted ? Color.green : (isResetting ? Color.gray.opacity(0.5) : Color.blue))
                        .foregroundColor(.white)
                        .cornerRadius(23)
                }
                .disabled(isResetting && !isCompleted)
                
                // 新增的好看按钮示例
                if !isResetting && !isCompleted {
                    Button(action: {
                        // 这里可以添加按钮的操作
                    }) {
                        HStack(spacing: 12) {
                            // 左侧图标
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 18))
                                    .foregroundColor(.orange)
                            }
                            
                            // 文字部分
                            VStack(alignment: .leading, spacing: 2) {
                                Text("查看帮助文档")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                                
                                Text("了解更多关于恢复出厂设置的信息")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            // 右侧箭头
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.orange)
                                .opacity(isHovering ? 1.0 : 0.7)
                                .offset(x: isHovering ? 5 : 0)
                                .animation(.spring(response: 0.3), value: isHovering)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(colorScheme == .dark ? Color(.darkGray).opacity(0.3) : Color.white)
                                .shadow(color: Color.black.opacity(0.1), radius: 5, x: 0, y: 2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(isHovering ? 0.5 : 0.2), lineWidth: 1)
                        )
                        .scaleEffect(isHovering ? 1.02 : 1.0)
                        .animation(.spring(response: 0.3), value: isHovering)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { hovering in
                        isHovering = hovering
                    }
                    .frame(width: 320)
                    .padding(.top, 10)
                    
                    // 彩色按钮组
                    VStack(spacing: 15) {
                        // 第一行按钮
                        HStack(spacing: 15) {
                            // 粉色按钮
                            ColorButton(color: .pink, title: "Pink Button")
                            
                            // 绿色按钮
                            ColorButton(color: .green, title: "Green Button")
                        }
                        
                        // 第二行按钮
                        HStack(spacing: 15) {
                            // 蓝色按钮
                            ColorButton(color: .blue, title: "Blue Button")
                            
                            // 红色按钮
                            ColorButton(color: .red, title: "Red Button")
                        }
                        
                        // 第三行按钮
                        HStack(spacing: 15) {
                            // 橙色按钮
                            ColorButton(color: .orange, title: "Orange Button")
                            
                            // 黄色按钮
                            ColorButton(color: .yellow, title: "Yellow Button", textColor: .black)
                        }
                    }
                    .padding(.top, 20)
                }
                
                // 占位空间，保持窗口大小一致
                Spacer(minLength: 80)
            }
            .padding(.horizontal, 30)
        }
        .frame(width: 500, height: 700) // 增加高度以适应新按钮
    }
    
    func resetFactory() {
        isResetting = true
        currentStep = 0
        
        // 模拟进度更新
        DispatchQueue.global(qos: .userInitiated).async {
            // 步骤1: 打开串口
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                currentStep = 1
            }
            
            // 步骤2-8: 模拟恢复出厂设置过程
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // 开始恢复出厂设置
                currentStep = 2
                
                // 启用 RTS
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    currentStep = 3
                    
                    // 等待中...
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        currentStep = 4
                        
                        // 禁用 RTS
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) {
                            currentStep = 5
                            
                            // 等待中...
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                currentStep = 6
                                
                                // 关闭串口
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    currentStep = 7
                                    
                                    // 重新打开串口
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        currentStep = 8
                                        
                                        // 完成
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            currentStep = 9
                                            
                                            // 设置为完成状态，但不重置界面
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                isResetting = false
                                                isCompleted = true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// 彩色按钮组件
struct ColorButton: View {
    var color: Color
    var title: String
    var textColor: Color = .white
    @State private var isHovering = false
    
    var body: some View {
        Button(action: {
            // 按钮点击操作
        }) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [color, color.opacity(0.8)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(8)
                .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 2)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .animation(.spring(response: 0.2), value: isHovering)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
