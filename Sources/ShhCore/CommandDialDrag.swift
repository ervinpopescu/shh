import CoreGraphics

/// Selection for a single uninterrupted drag. Navigation and dispatch happen only
/// after release; touching the center cancels the pending selection.
public struct CommandDialDrag: Equatable, Sendable {
    public private(set) var parentID: String?
    public private(set) var childID: String?
    public private(set) var returnedToCenter = false

    public init() {}

    public mutating func update(
        at point: CGPoint, inner: DialRadialLayout, outer: DialRadialLayout,
        nodes: [DialNode]
    ) {
        let dx = point.x - inner.center.x
        let dy = point.y - inner.center.y
        let distance = hypot(dx, dy)
        if distance < inner.itemRadius * 1.5 {
            returnedToCenter = returnedToCenter || parentID != nil || childID != nil
            parentID = nil
            childID = nil
            return
        }
        returnedToCenter = false
        let boundary = (inner.orbitRadius + outer.orbitRadius) / 2
        if distance < boundary || parentID == nil {
            let projected = CGPoint(
                x: inner.center.x + dx / distance * inner.orbitRadius,
                y: inner.center.y + dy / distance * inner.orbitRadius)
            if let index = inner.index(at: projected), nodes.indices.contains(index),
                nodes[index].isEnabled
            {
                parentID = nodes[index].id
            } else {
                parentID = nil
            }
            childID = nil
        }
        guard distance >= boundary,
            let parent = nodes.first(where: { $0.id == parentID }),
            !parent.children.isEmpty
        else { return }
        let childRing = DialRadialLayout.corner(
            center: outer.center, radius: outer.orbitRadius,
            itemRadius: outer.itemRadius, count: parent.children.count,
            placement: outer.startAngle < 0 ? .leading : .trailing)
        let projected = CGPoint(
            x: outer.center.x + dx / distance * outer.orbitRadius,
            y: outer.center.y + dy / distance * outer.orbitRadius)
        if let index = childRing.index(at: projected), parent.children.indices.contains(index),
            parent.children[index].isEnabled
        {
            childID = parent.children[index].id
        } else {
            childID = nil
        }
    }

    /// The release must still be near the selected ring. A group is returned
    /// as a node so the existing navigation.activate keeps it non-dispatching.
    public func releasedNode(
        at point: CGPoint, inner: DialRadialLayout, outer: DialRadialLayout,
        nodes: [DialNode]
    ) -> DialNode? {
        let distance = hypot(point.x - inner.center.x, point.y - inner.center.y)
        let boundary = (inner.orbitRadius + outer.orbitRadius) / 2
        guard let parent = nodes.first(where: { $0.id == parentID }), parent.isEnabled else {
            return nil
        }
        if distance >= boundary {
            guard abs(distance - outer.orbitRadius) <= outer.itemRadius * 1.4,
                let child = parent.children.first(where: { $0.id == childID }), child.isEnabled
            else { return nil }
            return child
        }
        guard abs(distance - inner.orbitRadius) <= inner.itemRadius * 1.4 else { return nil }
        return parent
    }
}
