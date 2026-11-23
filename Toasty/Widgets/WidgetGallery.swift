import AppKit
import SwiftUI

private struct PreviewKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Drawn as a preview (the gallery): no live terminal, no controls.
    var widgetPreview: Bool {
        get { self[PreviewKey.self] }
        set { self[PreviewKey.self] = newValue }
    }
}

/// Over the conversation while the gallery is open: the page dimmed, and
/// the Add Widget panel.
struct WidgetGalleryOverlay: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layout: WindowLayout

    var body: some View {
        ZStack(alignment: .top) {
            if store.galleryOpen, let w = store.active {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { store.galleryOpen = false }
                    .transition(.opacity)
                WidgetGallery(store: store, workspace: w)
                    .padding(.top, WidgetGrid.margin)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, Theme.Space.xl)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        // Under the tab row, as the widgets are.
        .padding(.top, layout.buttonsMidY > 0 ? layout.buttonsMidY * 2 : 52)
        .animation(.easeOut(duration: 0.16), value: store.galleryOpen)
    }
}

private struct WidgetGallery: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    @ObservedObject private var model = WidgetGalleryModel.shared

    var body: some View {
        let space = store.space(for: workspace)
        let layout = WidgetLayout(widgets: space?.widgets ?? [])
        let target = model.target(in: layout)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            HStack(spacing: 0) {
                kinds
                Rectangle().fill(Theme.Stroke.barDivider).frame(width: 1)
                preview
            }
            Rectangle().fill(Theme.Stroke.barDivider).frame(height: 1)
            footer(target: target, space: space)
        }
        .frame(maxWidth: 660)
        .frame(height: 600)
        .background(WidgetShellBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .onExitCommand { store.galleryOpen = false }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("Add Widget").font(.toasty(Theme.Size.title, .semibold))
            Spacer()
            BarIconButton(symbol: "xmark", tooltip: Tooltip(title: "Close", shortcut: "esc"),
                          size: CGSize(width: 28, height: 28)) { store.galleryOpen = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, Theme.Space.l + Theme.Space.xs)
        .padding(.trailing, Theme.Space.m)
        .frame(height: 56)
    }

    private var kinds: some View {
        VStack(spacing: Theme.Space.xxs) {
            ForEach(WidgetKind.gallery) { kind in
                KindRow(kind: kind, selected: model.kind == kind) {
                    model.kind = kind
                    model.placed = nil
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s)
        .frame(width: 252)
    }

    private var preview: some View {
        let preset = model.effectivePreset
        let item = WidgetItem(kind: model.kind, span: preset.span, units: preset.units)
        return VStack(spacing: Theme.Space.l) {
            SizePicker(presets: model.kind.presets, selection: Binding(get: { preset }, set: {
                model.preset = $0
                model.placed = nil
            }))
            .padding(.top, Theme.Space.l)
            Spacer(minLength: 0)
            WidgetContent(workspace: workspace, item: item, units: item.units)
                .environment(\.widget, WidgetContext(item: item, units: item.units))
                .environment(\.widgetPreview, true)
                .allowsHitTesting(false)
                .frame(width: WidgetGrid.width(span: item.span), height: WidgetGrid.height(item.units), alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .background(WidgetShellBackground())
                .id("\(model.kind.rawValue)-\(preset.rawValue)")
                .transition(.opacity)
            Text("\(preset.span) × \(preset.units) · \(Int(WidgetGrid.width(span: preset.span))) × \(Int(WidgetGrid.height(preset.units)))")
                .font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.Widget.crossfade, value: "\(model.kind.rawValue)-\(preset.rawValue)")
    }

    private func footer(target: WidgetItem?, space: WidgetSpace?) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(target != nil ? "Fits the free space. Drag the blue outline in the column to place it elsewhere."
                               : "No room for \(model.effectivePreset.title). Make Terminal shorter, or remove a widget.")
                .font(.toasty(Theme.Size.meta))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.s)
            Button("Add Widget") {
                guard let target, let space else { return }
                withAnimation(Theme.Widget.settle) {
                    store.setWidgets(space.widgets + [target], in: space.id)
                    store.galleryOpen = false
                }
            }
            .buttonStyle(WidgetButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(target == nil)
        }
        .padding(.horizontal, Theme.Space.l + Theme.Space.xs)
        .frame(height: 60)
    }
}

private struct KindRow: View {
    let kind: WidgetKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: kind.symbol)
                    .font(.toasty(Theme.Size.control))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Fill.subtle))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .strokeBorder(Theme.Stroke.border, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.toasty(Theme.Size.control, .medium)).foregroundStyle(.primary)
                    Text(kind.subtitle).font(.toasty(Theme.Size.meta)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s + Theme.Space.xxs)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Theme.Fill.selected : hovering ? Theme.Fill.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Small · Medium · Large, as the tab bar's capsules in a quiet track.
private struct SizePicker: View {
    let presets: [WidgetPreset]
    @Binding var selection: WidgetPreset

    var body: some View {
        HStack(spacing: 2) {
            ForEach(presets) { p in
                Button { selection = p } label: {
                    Text(p.title)
                        .font(.toasty(Theme.Size.meta, selection == p ? .medium : .regular))
                        .foregroundStyle(selection == p ? .primary : .secondary)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(selection == p ? Theme.Surface.page : Color.clear)
                            .liftShadow(selection == p))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.Fill.subtle))
    }
}

private extension View {
    @ViewBuilder func liftShadow(_ on: Bool) -> some View {
        if on { liftShadow() } else { self }
    }
}

/// The gallery's host over the conversation: takes clicks only while it's
/// open, so the conversation below gets them otherwise.
final class GalleryHostingView: NSHostingView<WidgetGalleryOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard WorkspaceStore.shared.galleryOpen else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
