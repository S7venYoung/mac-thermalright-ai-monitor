// SettingsView.swift — Settings window (SwiftUI)
//
// Tabs: General | Display | Device | About

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") {
                generalSettings
            }

            Tab("显示", systemImage: "display") {
                displaySettings
            }

            Tab("设备", systemImage: "cable.connector") {
                deviceSettings
            }

            Tab("关于", systemImage: "info.circle") {
                aboutView
            }
        }
        .frame(width: 480, height: 340)
    }

    // MARK: - General Tab

    private var generalSettings: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Text("需要以 .app 应用运行（调试构建不可用）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("刷新") {
                Picker("刷新间隔", selection: $state.refreshInterval) {
                    Text("0.5 秒（默认）").tag(0.5)
                    Text("1.0 秒").tag(1.0)
                    Text("2.0 秒").tag(2.0)
                }
                .onChange(of: state.refreshInterval) {
                    state.applySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display Tab

    private var displaySettings: some View {
        Form {
            Section("显示方案") {
                Picker("当前方案", selection: $state.currentSet) {
                    ForEach(DisplaySet.allCases) { set in
                        Text(set.displayName).tag(set)
                    }
                }
                .onChange(of: state.currentSet) {
                    state.applySettings()
                }
            }

            Section("中间模块") {
                Picker("左侧", selection: $state.middleLeft) {
                    ForEach(MiddleSlot.allCases) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .onChange(of: state.middleLeft) {
                    state.applySettings()
                }

                Picker("中间", selection: $state.middleCenter) {
                    ForEach(MiddleSlot.allCases) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .onChange(of: state.middleCenter) {
                    state.applySettings()
                }

                Picker("右侧", selection: $state.middleRight) {
                    ForEach(MiddleSlot.allCases) { slot in
                        Text(slot.displayName).tag(slot)
                    }
                }
                .onChange(of: state.middleRight) {
                    state.applySettings()
                }

                Text("三个模块保持固定，可自由组合。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("亮度") {
                HStack {
                    Slider(value: brightnessBinding, in: 1...10, step: 1) {
                        Text("亮度")
                    }
                    Text("\(state.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: state.brightness) {
                    state.applySettings()
                }
                Text("1 = 原始亮度，10 = 最高亮度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("旋转") {
                Toggle("旋转 180°", isOn: $state.rotateDisplay)
                    .onChange(of: state.rotateDisplay) {
                        state.applySettings()
                    }
                Text("如果屏幕画面上下颠倒，请开启此选项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Device Tab

    private var deviceSettings: some View {
        Form {
            Section("连接") {
                LabeledContent("状态") {
                    HStack {
                        Circle()
                            .fill(state.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isConnected ? "已连接" : "未连接")
                    }
                }

                if let info = state.deviceInfo {
                    LabeledContent("分辨率", value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected {
                    Button("重新连接") {
                        state.connect()
                    }
                }
            }

            Section("统计") {
                LabeledContent("已发送帧数", value: "\(state.frameCount)")
                LabeledContent("最后一帧", value: "\(state.lastFrameSize / 1024) KB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MacTR")
                .font(.title)
                .fontWeight(.semibold)

            Text("Thermalright Trofeo Vision 9.16 LCD 的 macOS 驱动")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("使用 Swift 6.3 + libusb 构建")
                Text("协议：LY Bulk（thermalright-trcc-linux）")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[Settings] Launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(state.brightness) },
            set: { state.brightness = Int($0) }
        )
    }
}
