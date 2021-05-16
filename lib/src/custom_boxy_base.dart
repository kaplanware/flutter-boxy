import 'package:boxy/src/inflating_element.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Base class for the [ParentData] provided by [RenderBoxyMixin] clients.
class BaseBoxyParentData<ChildType extends RenderObject>
  extends ContainerBoxParentData<ChildType>
  implements InflatingParentData<ChildType> {
  /// An id provided by [BoxyId] or inflation methods on the delegate.
  @override
  Object? id;

  /// Data provided by [BoxyId] or intermediate storage for delegates.
  dynamic userData;

  /// The paint transform that is used by the default paint, hitTest, and
  /// applyPaintTransform implementations.
  Matrix4 transform = Matrix4.identity();
}

/// Base mixin of [RenderBoxy] and [RenderSliverBoxy] that is agnostic to layout
/// protocols.
mixin RenderBoxyMixin<
  ChildType extends RenderObject,
  ParentDataType extends BaseBoxyParentData<ChildType>,
  ChildHandleType extends BaseBoxyChild
> on RenderObject implements
  ContainerRenderObjectMixin<ChildType, ParentDataType>,
  InflatingRenderObjectMixin<ChildType, ParentDataType, ChildHandleType>
{
  BoxyDelegatePhase _debugPhase = BoxyDelegatePhase.none;

  /// A variable that can be used by [delegate] to store data between layout.
  dynamic layoutData;

  /// The current painting context, only valid during paint.
  PaintingContext? paintingContext;

  /// The current paint offset, only valid during paint or hit testing.
  Offset? paintOffset;

  /// The current canvas, only valid during paint.
  Canvas? canvas;

  /// The current phase in the render pipeline that this boxy is performing.
  BoxyDelegatePhase get debugPhase => _debugPhase;
  set debugPhase(BoxyDelegatePhase state) {
    assert(() {
      _debugPhase = state;
      return true;
    }());
  }

  /// Throws an error as a result of an incorrect layout phase e.g. calling
  /// inflate during a dry layout.
  ///
  /// Override to improve the reporting of these kinds of errors.
  void debugThrowLayout(FlutterError error) {
    throw error;
  }

  @override
  void performLayout() {
    super.performLayout();
    assert(() {
      if (debugChildrenNeedingLayout.isNotEmpty) {
        if (debugChildrenNeedingLayout.length > 1) {
          throw FlutterError(
            'The $delegate boxy delegate forgot to lay out the following children:\n'
            '  ${debugChildrenNeedingLayout.map(_debugDescribeChild).join("\n  ")}\n'
            'Each child must be laid out exactly once.'
          );
        } else {
          throw FlutterError(
            'The $delegate boxy delegate forgot to lay out the following child:\n'
            '  ${_debugDescribeChild(debugChildrenNeedingLayout.single)}\n'
            'Each child must be laid out exactly once.'
          );
        }
      }
      return true;
    }());
  }

  String _debugDescribeChild(Object id) => '$id: ${childHandleMap[id]!.render}';

  /// The current delegate of this boxy.
  BaseBoxyDelegate get delegate;
  set delegate(covariant BaseBoxyDelegate newDelegate);

  /// Marks the object for needing layout, paint, build. or compositing bits
  /// update as a result of the delegate changing.
  void notifyChangedDelegate(BaseBoxyDelegate oldDelegate) {
    if (delegate == oldDelegate)
      return;

    final neededCompositing = oldDelegate.needsCompositing;

    if (
      delegate.runtimeType != oldDelegate.runtimeType
      || delegate.shouldRelayout(oldDelegate)
    ) {
      markNeedsLayout();
    } else if (delegate.shouldRepaint(oldDelegate)) {
      markNeedsPaint();
    }

    if (neededCompositing != delegate.needsCompositing) {
      markNeedsCompositingBitsUpdate();
    }

    if (attached) {
      oldDelegate._relayout?.removeListener(markNeedsLayout);
      oldDelegate._repaint?.removeListener(markNeedsPaint);
      delegate._relayout?.addListener(markNeedsLayout);
      delegate._repaint?.addListener(markNeedsPaint);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    delegate._relayout?.addListener(markNeedsLayout);
    delegate._repaint?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    delegate._relayout?.removeListener(markNeedsLayout);
    delegate._repaint?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    paintingContext = context;
    delegate.wrapContext(this, BoxyDelegatePhase.painting, () {
      context.canvas.save();
      context.canvas.translate(offset.dx, offset.dy);
      paintOffset = Offset.zero;
      delegate.paint();
      context.canvas.restore();
      paintOffset = offset;
      delegate.paintChildren();
      context.canvas.save();
      context.canvas.translate(offset.dx, offset.dy);
      paintOffset = Offset.zero;
      delegate.paintForeground();
      context.canvas.restore();
    });
    paintingContext = null;
    paintOffset = null;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final parentData = child.parentData as BaseBoxyParentData;
    transform.multiply(parentData.transform);
  }

  @override
  bool get alwaysNeedsCompositing => delegate.needsCompositing;
}

/// The current phase in the render pipeline that the boxy is in.
///
/// See also:
///
///  * [RenderBoxyMixin], which exposes this value.
enum BoxyDelegatePhase {
  /// The delegate is not performing work.
  none,

  /// Layout is being performed.
  layout,

  /// Intrinsic layouts are currently being performed.
  intrinsics,

  /// A dry layout pass is currently being performed.
  dryLayout,

  /// The boxy is currently painting.
  painting,

  /// The boxy is currently being hit test.
  hitTest,
}

/// Cache for [Layer] objects, used by [BoxyLayerContext] methods.
///
/// Preserving [Layer]s between paints can significantly improve performance
/// in some cases, this class provides a convenient way of identifying them.
///
/// See also:
///
///  * [BoxyDelegate]
///  * [BoxyLayerContext]
class LayerKey {
  /// The current cached layer.
  Layer? layer;
}

/// A convenient wrapper to [PaintingContext], provides methods to push
/// compositing [Layer]s from the paint methods of [BoxyDelegate].
///
/// You can obtain a layer context in a delegate through the
/// [BoxyDelegate.layers] getter.
///
/// See also:
///
///  * [BoxyDelegate], which has an example on how to use layers.
class BoxyLayerContext {
  final RenderBoxyMixin _render;

  BoxyLayerContext._(this._render);

  /// Pushes a [ContainerLayer] to the current recording, calling [paint] to
  /// paint on top of the layer.
  ///
  /// {@template boxy.custom_boxy.BoxyLayerContext.push.bounds}
  /// The [bounds] argument defines the bounds in which the [paint] should
  /// paint, this is useful for debugging tools and does not affect rendering.
  /// {@endtemplate}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushLayer]
  void push({
    required VoidCallback paint,
    ContainerLayer? layer,
    Rect? bounds,
    Offset offset = Offset.zero,
  }) {
    final oldContext = _render.paintingContext;
    final oldOffset = _render.paintOffset;
    try {
      if (layer == null) {
        paint();
      } else {
        oldContext!.pushLayer(
          layer,
          (context, offset) {
            _render.paintingContext = context;
            _render.paintOffset = offset;
            paint();
          },
          offset + _render.paintOffset!,
          childPaintBounds: bounds,
        );
      }
    } finally {
      _render.paintingContext = oldContext;
      _render.paintOffset = oldOffset;
    }
  }

  /// Pushes a [Layer] to the compositing tree similar to [push], but can't
  /// paint anything on top of it.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.addLayer]
  void add({required Layer layer}) {
    _render.paintingContext!.addLayer(layer);
  }

  /// Pushes a [ClipPathLayer] to the compositing tree, calling [paint] to paint
  /// on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushClipPath]
  void clipPath({
    required Path path,
    required VoidCallback paint,
    Clip clipBehavior = Clip.antiAlias,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    final offsetClipPath = path.shift(offset + _render.paintOffset!);
    ClipPathLayer layer;
    if (key?.layer is ClipPathLayer) {
      layer = (key!.layer as ClipPathLayer)
        ..clipPath = offsetClipPath
        ..clipBehavior = clipBehavior;
    } else {
      layer = ClipPathLayer(
        clipPath: offsetClipPath,
        clipBehavior: clipBehavior,
      );
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, offset: offset, bounds: bounds);
  }

  /// Pushes a [ClipRectLayer] to the compositing tree, calling [paint] to paint
  /// on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushClipRect]
  void clipRect({
    required Rect rect,
    required VoidCallback paint,
    Clip clipBehavior = Clip.antiAlias,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    final offsetClipRect = rect.shift(offset + _render.paintOffset!);
    ClipRectLayer layer;
    if (key?.layer is ClipRectLayer) {
      layer = (key!.layer as ClipRectLayer)
        ..clipRect = offsetClipRect
        ..clipBehavior = clipBehavior;
    } else {
      layer = ClipRectLayer(
        clipRect: offsetClipRect,
        clipBehavior: clipBehavior,
      );
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, offset: offset, bounds: bounds);
  }

  /// Pushes a [ClipRRectLayer] to the compositing tree, calling [paint] to
  /// paint on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushClipRRect]
  void clipRRect({
    required RRect rrect,
    required VoidCallback paint,
    Clip clipBehavior = Clip.antiAlias,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    final offsetClipRRect = rrect.shift(offset + _render.paintOffset!);
    ClipRRectLayer layer;
    if (key?.layer is ClipRRectLayer) {
      layer = (key!.layer as ClipRRectLayer)
        ..clipRRect = offsetClipRRect
        ..clipBehavior = clipBehavior;
    } else {
      layer = ClipRRectLayer(
        clipRRect: offsetClipRRect,
        clipBehavior: clipBehavior,
      );
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, offset: offset, bounds: bounds);
  }

  /// Pushes a [ColorFilterLayer] to the compositing tree, calling [paint] to
  /// paint on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushColorFilter]
  void colorFilter({
    required ColorFilter colorFilter,
    required VoidCallback paint,
    Rect? bounds,
    LayerKey? key,
  }) {
    ColorFilterLayer layer;
    if (key?.layer is ColorFilterLayer) {
      layer = (key!.layer as ColorFilterLayer)..colorFilter = colorFilter;
    } else {
      layer = ColorFilterLayer(colorFilter: colorFilter);
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, bounds: bounds);
  }

  /// Pushes an [OffsetLayer] to the compositing tree, calling [paint] to paint
  /// on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushTransform]
  void offset({
    required Offset offset,
    required VoidCallback paint,
    Rect? bounds,
    LayerKey? key,
  }) {
    OffsetLayer layer;
    if (key?.layer is OffsetLayer) {
      layer = (key!.layer as OffsetLayer)..offset = offset;
    } else {
      layer = OffsetLayer(offset: offset);
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, bounds: bounds);
  }

  /// Pushes an [TransformLayer] to the compositing tree, calling [paint] to
  /// paint on top of the layer.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushTransform]
  void transform({
    required Matrix4 transform,
    required VoidCallback paint,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    final layerOffset = _render.paintOffset! + offset;
    TransformLayer layer;
    if (key?.layer is TransformLayer) {
      layer = (key!.layer as TransformLayer)
        ..transform = transform
        ..offset = layerOffset;
    } else {
      layer = TransformLayer(
        transform: transform,
        offset: layerOffset,
      );
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, offset: -_render.paintOffset!, bounds: bounds);
  }

  /// Pushes an [OpacityLayer] to the compositing tree, calling [paint] to paint
  /// on top of the layer.
  ///
  /// The `alpha` argument is the alpha value to use when blending. An alpha
  /// value of 0 means the painting is fully transparent and an alpha value of
  /// 255 means the painting is fully opaque.
  ///
  /// {@macro boxy.custom_boxy.BoxyLayerContext.push.bounds}
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushOpacity]
  void alpha({
    required int alpha,
    required VoidCallback paint,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    OpacityLayer layer;
    if (key?.layer is OffsetLayer) {
      layer = (key!.layer as OpacityLayer)..alpha = alpha;
    } else {
      layer = OpacityLayer(alpha: alpha);
      key?.layer = layer;
    }
    push(layer: layer, paint: paint, offset: offset, bounds: bounds);
  }

  /// Pushes an [OpacityLayer] to the compositing tree, calling [paint] to paint
  /// on top of the layer.
  ///
  /// This is the same as [alpha] but takes a fraction instead of an integer,
  /// where 0.0 means the painting is fully transparent and an opacity value of
  //  1.0 means the painting is fully opaque.
  ///
  /// See also:
  ///
  ///  * [PaintingContext.pushOpacity]
  void opacity({
    required double opacity,
    required VoidCallback paint,
    Offset offset = Offset.zero,
    Rect? bounds,
    LayerKey? key,
  }) {
    return alpha(
      alpha: (opacity * 255).round(),
      paint: paint,
      offset: offset,
      bounds: bounds,
      key: key,
    );
  }
}

/// Base class of child handles managed by [RenderBoxyMixin] clients.
///
/// This typically not used directly, instead obtain a child handle from
/// BoxyDelegate.getChild.
class BaseBoxyChild extends InflatedChildHandle {
  /// Constructs a handle to children managed by [RenderBoxyMixin] clients.
  BaseBoxyChild({
    required Object id,
    required InflatingRenderObjectMixin parent,
    RenderObject? render,
    Widget? widget,
  }) :
    assert(render == null || render.parentData != null),
    super(id: id, parent: parent, render: render, widget: widget);

  bool _ignore = false;

  BaseBoxyParentData get _parentData =>
    render.parentData as BaseBoxyParentData;

  /// A variable that can store arbitrary data by the [BoxyDelegate] during
  /// layout.
  ///
  /// See also:
  ///
  ///  * [ParentData]
  dynamic get parentData => _parentData.userData;

  set parentData(dynamic value) {
    _parentData.userData = value;
  }

  RenderBoxyMixin get _parent {
    return render.parent as RenderBoxyMixin;
  }

  /// Paints the child in the current paint context, this should only be called
  /// in [BoxyDelegate.paintChildren].
  ///
  /// Note that painting a child at an offset will not transform hit tests,
  /// you may want to use [BoxyChild.setTransform] instead.
  ///
  /// This the canvas must be restored before calling this because the child
  /// might need its own [Layer] which is rendered in a separate context.
  void paint({Offset? offset, Matrix4? transform}) {
    assert(
      offset == null || transform != null,
      'Only one of offset and transform can be provided at the same time',
    );

    if (_ignore) return;
    assert(() {
      if (_parent.debugPhase != BoxyDelegatePhase.painting) {
        throw FlutterError(
          'The $this boxy delegate tried to paint a child outside of the paint method.'
        );
      }

      return true;
    }());

    if (offset == null && transform == null) {
      transform = _parentData.transform;
    }

    if (transform != null) {
      offset = MatrixUtils.getAsTranslation(transform);
      if (offset == null) {
        _parent.delegate.layers.transform(
          transform: transform,
          paint: () {
            _parent.paintingContext!.paintChild(render, _parent.paintOffset!);
          },
        );
        return;
      }
    }

    final paintOffset = _parent.paintOffset!;

    _parent.paintingContext!.paintChild(
      render,
      offset == null ? paintOffset : paintOffset + offset,
    );
  }

  /// Whether or not this child should be ignored from painting and hit testing.
  bool get isIgnored => _ignore;

  /// Causes this child to be dropped from paint and hit testing, the child
  /// still needs to be layed out.
  void ignore([bool value = true]) {
    _ignore = value;
  }

  @override
  String toString() => 'BoxyChild(id: $id)';
}

/// An error that indicates [BaseBoxyDelegate.inflate] was called during a dry
/// layout.
class CannotInflateError<DelegateType extends BaseBoxyDelegate> extends FlutterError {
  /// The delegate that caused the error.
  final BaseBoxyDelegate delegate;

  /// The associated RenderObject.
  final RenderBoxyMixin<RenderObject, BaseBoxyParentData, BaseBoxyChild> render;

  /// Constructs an inflation error given the delegate and RenderObject.
  CannotInflateError({
    required this.delegate,
    required this.render,
  }) : super.fromParts([
    ErrorSummary(
      'The $delegate boxy attempted to inflate a widget during a dry layout.'
    ),
    ErrorDescription(
      'This happens if an ancestor of the boxy (e.g. Wrap) requires a '
      'dry layout, but your size also depends on an inflated widget.',
    ),
    ErrorDescription(
      'If your boxy\'s size does not depend on the size of this widget you '
      'can skip the call to `inflate` when `isDryLayout` is true',
    ),
  ]);
}

/// Extension to expose the internals of [BaseBoxyDelegate].
///
/// The purpose of this is to prevent users of CustomBoxy from accidentally
/// setting [BaseBoxyDelegate.render], which is required by other libraries but
/// otherwise an implementation detail.
extension BoxyDelegateInternals<
  LayoutData extends Object,
  ChildType extends RenderObject,
  ParentDataType extends BaseBoxyParentData<ChildType>,
  ChildHandleType extends BaseBoxyChild
> on BaseBoxyDelegate<LayoutData, ChildHandleType> {
  /// Wraps [func] with a new context given [render] and [phase].
  T wrapContext<T>(
    RenderBoxyMixin<ChildType, ParentDataType, ChildHandleType> render,
    BoxyDelegatePhase phase,
    T Function() func,
  ) {
    // A particular delegate could be called reentrantly, e.g. if it used
    // by both a parent and a child. So, we must restore the context when
    // we return.

    final prevRender = _render;
    _render = render;
    render.debugPhase = phase;

    try {
      return func();
    } finally {
      render.debugPhase = BoxyDelegatePhase.none;
      _render = prevRender;
    }
  }
}

/// Base class for delegates that control the layout and paint of multiple
/// children.
class BaseBoxyDelegate<LayoutData extends Object, ChildHandleType extends BaseBoxyChild> {
  /// Constructs a BaseBoxyDelegate with optional [relayout] and [repaint]
  /// [Listenable]s.
  BaseBoxyDelegate({
    Listenable? relayout,
    Listenable? repaint,
  }) : _relayout = relayout, _repaint = repaint;

  final Listenable? _relayout;
  final Listenable? _repaint;

  RenderBoxyMixin<RenderObject, BaseBoxyParentData, ChildHandleType>? _render;

  /// The current phase in the render pipeline that this boxy is performing,
  /// only valid in debug mode.
  BoxyDelegatePhase get debugPhase =>
    _render == null ? BoxyDelegatePhase.none : _render!.debugPhase;

  /// A slot to hold additional data created during [layout] which can be used
  /// while painting and hit testing.
  LayoutData? get layoutData => render.layoutData as LayoutData?;

  set layoutData(LayoutData? data) {
    assert(() {
      if (debugPhase != BoxyDelegatePhase.layout) {
        throw FlutterError(
          'The $this boxy delegate attempted to set layout data outside of the layout method.\n'
        );
      }
      return true;
    }());
    _render!.layoutData = data;
  }

  /// The RenderBoxyMixin of the current context.
  RenderBoxyMixin<RenderObject, BaseBoxyParentData, ChildHandleType> get render {
    assert(() {
      if (_render == null || _render!.debugPhase == BoxyDelegatePhase.none) {
        throw FlutterError(
          'The $this boxy delegate attempted to get the context outside of its normal lifecycle.\n'
          'You should only access the BoxyDelegate from its overridden methods.'
        );
      }
      return true;
    }());
    return _render!;
  }

  /// A list of each [BoxyChild] handle, this should not be modified in any way.
  List<BaseBoxyChild> get children => render.childHandles;

  /// Returns true if a child exists with the specified [id].
  bool hasChild(Object id) => render.childHandleMap.containsKey(id);

  /// Gets the child handle with the specified [id].
  ChildHandleType getChild(Object id) {
    final child = render.childHandleMap[id];
    assert(() {
      if (child == null) {
        throw FlutterError(
          'The $this boxy delegate attempted to get a nonexistent child.\n'
          'There is no child with the id "$id".'
        );
      }
      return true;
    }());
    return child!;
  }

  /// Gets the current build context of this boxy.
  BuildContext get buildContext => render.context;

  /// The number of children that have not been given a [LayoutId], this
  /// guarantees there are child ids between 0 (inclusive) to indexedChildCount
  /// (exclusive).
  int get indexedChildCount => render.indexedChildCount;

  /// The current canvas, should only be accessed from paint methods.
  Canvas get canvas {
    assert(() {
      if (debugPhase != BoxyDelegatePhase.painting) {
        throw FlutterError(
          'The $this boxy delegate attempted to access the canvas outside of a paint method.'
        );
      }
      return true;
    }());
    return render.canvas!;
  }

  /// The offset of the current paint context.
  ///
  /// This offset applies to to [paint] and [paintForeground] by default, you
  /// should translate by this in [paintChildren] if you paint to [canvas].
  Offset get paintOffset {
    assert(() {
      if (debugPhase != BoxyDelegatePhase.painting) {
        throw FlutterError(
          'The $this boxy delegate attempted to access the paint offset outside of a paint method.'
        );
      }
      return true;
    }());
    return render.paintOffset!;
  }

  /// The current painting context, should only be accessed from paint methods.
  PaintingContext get paintingContext {
    assert(() {
      if (debugPhase != BoxyDelegatePhase.painting) {
        throw FlutterError(
          'The $this boxy delegate attempted to access the paint context outside of a paint method.'
        );
      }
      return true;
    }());
    return render.paintingContext!;
  }

  BoxyLayerContext? _layers;
  
  /// The current layer context, useful for pushing [Layer]s to the scene during
  /// [paintChildren].
  ///
  /// Delegates that push layers should override [needsCompositing] to return
  /// true.
  BoxyLayerContext get layers => _layers ??= BoxyLayerContext._(render);

  /// Paints a [ContainerLayer] compositing layer in the current painting
  /// context with an optional [painter] callback, this should only be called in
  /// [paintChildren].
  ///
  /// This is useful if you wanted to apply filters to your children, for example:
  ///
  /// ```dart
  /// paintLayer(
  ///   OpacityLayer(alpha: 127),
  ///   painter: getChild(#title).paint,
  /// );
  /// ```
  @Deprecated('Use layers.push instead')
  void paintLayer(ContainerLayer layer, {
    VoidCallback? painter,
    Offset? offset,
    Rect? debugBounds,
  }) {
    final render = this.render;
    paintingContext.pushLayer(layer, (context, offset) {
      final lastContext = render.paintingContext;
      final lastOffset = render.paintOffset;
      render.paintingContext = context;
      render.paintOffset = lastOffset;
      if (painter != null) painter();
      render.paintingContext = lastContext;
      render.paintOffset = lastOffset;
    }, offset ?? render.paintOffset!, childPaintBounds: debugBounds);
  }

  /// Dynamically inflates a widget as a child of this boxy, should only be
  /// called in [layout].
  ///
  /// If [id] is not provided the resulting child has an id of [indexedChildCount]
  /// which gets incremented.
  ///
  /// After calling this method the child becomes available with [getChild], it
  /// is removed before the next call to [layout].
  ///
  /// A child's state will only be preserved if inflated with the same id as the
  /// previous layout.
  ///
  /// Unlike children passed to the widget, [Key]s cannot be used to move state
  /// from one child id to another. You may hit duplicate [GlobalKey] assertions
  /// from children inflated during the previous layout.
  ChildHandleType inflate(Widget widget, {Object? id}) {
    final render = this.render;
    assert(() {
      if (debugPhase == BoxyDelegatePhase.dryLayout) {
        render.debugThrowLayout(CannotInflateError(delegate: this, render: render));
      } else if (debugPhase != BoxyDelegatePhase.layout) {
        throw FlutterError(
          'The $this boxy attempted to inflate a widget outside of the layout method.\n'
          'You should only call `inflate` from its overridden methods.'
        );
      }
      return true;
    }());
    return render.inflate(widget, id: id);
  }

  /// Override this method to return true when the children need to be
  /// laid out.
  ///
  /// This should compare the fields of the current delegate and the given
  /// `oldDelegate` and return true if the fields are such that the layout would
  /// be different.
  bool shouldRelayout(covariant BaseBoxyDelegate oldDelegate) => false;

  /// Override this method to return true when the children need to be
  /// repainted.
  ///
  /// This should compare the fields of the current delegate and the given
  /// `oldDelegate` and return true if the fields are such that the paint would
  /// be different.
  ///
  /// This is only called if [shouldRelayout] returns false so it doesn't need
  /// to check fields that have already been checked by your [shouldRelayout].
  bool shouldRepaint(covariant BaseBoxyDelegate oldDelegate) => false;

  /// Override this method to return true if the [paint] method will push one or
  /// more layers to [paintingContext].
  bool get needsCompositing => false;

  /// Override this method to include additional information in the
  /// debugging data printed by [debugDumpRenderTree] and friends.
  ///
  /// By default, returns the [runtimeType] of the class.
  @override
  String toString() => '$runtimeType';

  /// Override this method to paint above children.
  ///
  /// This method has access to [canvas] and [paintingContext] for painting.
  ///
  /// You can get the size of the widget with `render.size`.
  void paintForeground() {}

  /// Override this method to change how children get painted.
  ///
  /// This method has access to [canvas] and [paintingContext] for painting.
  ///
  /// If you paint to [canvas] here you should translate by [paintOffset] before
  /// painting yourself and restore before painting children. This translation
  /// is required because a child might need its own [Layer] which is rendered
  /// in a separate context.
  ///
  /// You can get the size of the widget with `render.size`.
  void paintChildren() {
    for (final child in children) child.paint();
  }

  /// Override this method to paint below children.
  ///
  /// This method has access to [canvas] and [paintingContext] for painting.
  ///
  /// You can get the size of the widget with `render.size`.
  void paint() {}

  /// Override to change the minimum width that this box could be without
  /// failing to correctly paint its contents within itself, without clipping.
  ///
  /// See also:
  ///
  ///  * [RenderBox.computeMinIntrinsicWidth], which has usage examples.
  double minIntrinsicWidth(double height) {
    assert(() {
      if (!RenderObject.debugCheckingIntrinsics) {
        throw FlutterError(
          'Something tried to get the minimum intrinsic width of the boxy delegate $this.\n'
          'You must override minIntrinsicWidth to use the intrinsic width.'
        );
      }
      return true;
    }());
    return 0.0;
  }

  /// Override to change the maximum width that this box could be without
  /// failing to correctly paint its contents within itself, without clipping.
  ///
  /// See also:
  ///
  ///  * [RenderBox.computeMinIntrinsicWidth], which has usage examples.
  double maxIntrinsicWidth(double height) {
    assert(() {
      if (!RenderObject.debugCheckingIntrinsics) {
        throw FlutterError(
          'Something tried to get the maximum intrinsic width of the boxy delegate $this.\n'
          'You must override maxIntrinsicWidth to use the intrinsic width.'
        );
      }
      return true;
    }());
    return 0.0;
  }

  /// Override to change the minimum height that this box could be without
  /// failing to correctly paint its contents within itself, without clipping.
  ///
  /// See also:
  ///
  ///  * [RenderBox.computeMinIntrinsicWidth], which has usage examples.
  double minIntrinsicHeight(double width) {
    assert(() {
      if (!RenderObject.debugCheckingIntrinsics) {
        throw FlutterError(
          'Something tried to get the minimum intrinsic height of the boxy delegate $this.\n'
          'You must override minIntrinsicHeight to use the intrinsic width.'
        );
      }
      return true;
    }());
    return 0.0;
  }

  /// Override to change the maximum height that this box could be without
  /// failing to correctly paint its contents within itself, without clipping.
  ///
  /// See also:
  ///
  ///  * [RenderBox.computeMinIntrinsicWidth], which has usage examples.
  double maxIntrinsicHeight(double width) {
    assert(() {
      if (!RenderObject.debugCheckingIntrinsics) {
        throw FlutterError(
          'Something tried to get the maximum intrinsic height of the boxy delegate $this.\n'
          'You must override maxIntrinsicHeight to use the intrinsic width.'
        );
      }
      return true;
    }());
    return 0.0;
  }
}

/// Widget that can provide data to the parent [CustomBoxy].
///
/// Similar to how [LayoutId] works, the parameters of this widget
/// can influence layout and paint behavior of its direct ancestor in the render
/// tree.
///
/// The [data] passed to this widget will be available to [BoxyDelegate] via
/// [BoxyChild.parentData].
///
/// See also:
///
///  * [CustomBoxy], which can use the data this widget provides.
///  * [ParentDataWidget], which has a more technical description of how this
///    works.
class BoxyId<T extends Object> extends ParentDataWidget {
  /// The object that identifies the child.
  final Object? id;

  /// Whether [data] was provided to this widget
  final bool hasData;

  final T? _data;

  /// Whether this widget rebuilding should always repaint the parent.
  final bool alwaysRepaint;

  /// Whether this widget rebuilding should always relayout the parent.
  final bool alwaysRelayout;

  /// Constructs a BoxyData with an optional id, data, and child.
  const BoxyId({
    this.id,
    Key? key,
    bool? hasData,
    T? data,
    required Widget child,
    this.alwaysRelayout = true,
    this.alwaysRepaint = true,
  }) : hasData = hasData ?? data != null,
       _data = data,
       super(
         key: key,
         child: child,
       );

  /// The data to provide to the parent.
  T get data {
    assert(hasData);
    return _data!;
  }

  @override
  void applyParentData(RenderObject renderObject) {
    assert(renderObject.parentData is BaseBoxyParentData);
    final parentData = renderObject.parentData! as BaseBoxyParentData;
    final parent = renderObject.parent as RenderObject;
    final dynamic oldData = parentData.userData;
    if (
      // Avoid calling shouldRelayout if old data is null
      (oldData == null && hasData) || shouldRelayout(oldData as T)
    ) {
      parent.markNeedsLayout();
    } else if (shouldRepaint(oldData)) {
      parent.markNeedsPaint();
    }
    parentData.userData = data;
  }

  @override
  Type get debugTypicalAncestorWidgetClass => LayoutInflatingWidget;

  /// Whether the difference in [data] should result in a relayout, defaults to
  /// [alwaysRelayout].
  bool shouldRelayout(T oldData) => alwaysRelayout;

  /// Whether the difference in [data] should result in a repaint, defaults to
  /// [alwaysRepaint].
  bool shouldRepaint(T oldData) => alwaysRelayout;
}