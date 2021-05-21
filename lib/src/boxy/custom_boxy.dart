import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../axis_utils.dart';
import 'box_child.dart';
import 'custom_boxy_base.dart';
import 'inflating_element.dart';

/// A widget that uses a delegate to control the layout of multiple children.
///
/// This is essentially a more powerful version of [CustomMultiChildLayout],
/// it allows you to inflate, constrain, and lay out each child manually, it
/// also allows the size of the widget to depend on the layout of its children.
///
/// In most cases this is overkill, you may want to check if some combination
/// of [Stack], [LayoutBuilder], [CustomMultiChildLayout], and [Flow] is more
/// suitable.
///
/// Children can be given an id using [BoxyId], otherwise they are given an
/// incrementing int id in the provided order, for example:
///
/// ```dart
/// CustomBoxy(
///   delegate: MyBoxyDelegate(),
///   children: [
///     Container(color: Colors.red)), // Child 0
///     BoxyId(id: #green, child: Container(color: Colors.green)),
///     Container(color: Colors.green)), // Child 1
///   ],
/// );
/// ```
///
/// See also:
///
///  * [BoxyDelegate], the base class of a CustomBoxy delegate.
class CustomBoxy extends LayoutInflatingWidget {
  /// Constructs a CustomBoxy with a delegate and optional set of children.
  const CustomBoxy({
    Key? key,
    required this.delegate,
    List<Widget> children = const <Widget>[],
  }) : super(
    key: key,
    children: children,
  );

  /// The delegate that controls the layout of the children.
  final BoxyDelegate delegate;

  @override
  _RenderBoxy createRenderObject(BuildContext context) {
    return _RenderBoxy(delegate: delegate);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderBoxy renderObject) {
    renderObject.delegate = delegate;
  }
}

class _RenderBoxy extends RenderBox with
  RenderBoxyMixin<RenderBox, BoxyParentData, BoxyChild>,
  ContainerRenderObjectMixin<RenderBox, BoxyParentData>,
  InflatingRenderObjectMixin<RenderBox, BoxyParentData, BoxyChild> {
  BoxConstraints? _dryConstraints;

  BoxyDelegate _delegate;

  @override
  BoxHitTestResult? hitTestResult;

  @override
  void prepareChild(BoxyChild child) {
    super.prepareChild(child);
    final parentData = child.render.parentData as BoxyParentData;
    parentData.drySize = null;
    parentData.dryTransform = null;
  }

  _RenderBoxy({
    required BoxyDelegate delegate,
  }) : _delegate = delegate;

  @override
  BoxyDelegate get delegate => _delegate;

  @override
  set delegate(BoxyDelegate newDelegate) {
    final oldDelegate = delegate;
    _delegate = newDelegate;
    notifyChangedDelegate(oldDelegate);
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BoxyParentData)
      child.parentData = BoxyParentData();
  }

  @override
  void performInflatingLayout() {
    wrapPhase(BoxyDelegatePhase.layout, () {
      var resultSize = constraints.smallest;
      resultSize = delegate.layout();
      size = constraints.constrain(resultSize);
    });
  }

  @override
  void debugThrowLayout(FlutterError error) {
    debugCannotComputeDryLayout(error: error);
    super.debugThrowLayout(error);
  }

  @override
  BoxyChild createChild({
    required Object id,
    Widget? widget,
    RenderObject? render,
  }) {
    return BoxyChild(
      id: id,
      parent: this,
      widget: widget,
      render: render,
    );
  }

  @override
  bool get isDryLayout => _dryConstraints != null;

  @override
  Size computeDryLayout(BoxConstraints dryConstraints) {
    _dryConstraints = dryConstraints;
    Size? resultSize;
    try {
      wrapPhase(BoxyDelegatePhase.dryLayout, () {
        resultSize = delegate.layout();
        assert(resultSize != null);
        resultSize = dryConstraints.constrain(resultSize!);
      });
    } on CannotInflateError {
      return Size.zero;
    } finally {
      _dryConstraints = null;
    }
    return resultSize!;
  }

  @override
  double computeMinIntrinsicWidth(double height) => wrapPhase(
    BoxyDelegatePhase.intrinsics, () => delegate.minIntrinsicWidth(height)
  );

  @override
  double computeMaxIntrinsicWidth(double height) => wrapPhase(
    BoxyDelegatePhase.intrinsics, () => delegate.maxIntrinsicWidth(height)
  );

  @override
  double computeMinIntrinsicHeight(double width) => wrapPhase(
    BoxyDelegatePhase.intrinsics, () => delegate.minIntrinsicHeight(width)
  );

  @override
  double computeMaxIntrinsicHeight(double width) => wrapPhase(
    BoxyDelegatePhase.intrinsics, () => delegate.maxIntrinsicHeight(width)
  );

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    hitTestResult = result;
    paintOffset = position;
    try {
      return wrapPhase(
        BoxyDelegatePhase.hitTest, () {
          return delegate.hitTest(position);
        }
      );
    } finally {
      hitTestResult = null;
      paintOffset = null;
    }
  }

  @override
  bool hitTestBoxChild({required RenderBox child, required Offset position, required Matrix4 transform}) {
    return hitTestResult!.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (result, position) {
        return child.hitTest(result, position: position);
      },
    );
  }

  @override
  bool hitTestSliverChild({required RenderSliver child, required Offset position, required Matrix4 transform}) {
    position = position.rotateWithAxis(child.constraints.axis);
    return hitTestResult!.addWithPaintTransform(
      transform: transform,
      position: position,
      hitTest: (result, position) {
        return child.hitTest(
          SliverHitTestResult.wrap(result),
          crossAxisPosition: position.dx,
          mainAxisPosition: position.dy,
        );
      },
    );
  }
}

/// A delegate that controls the layout and paint of child widgets, used by
/// [CustomBoxy].
///
/// Delegates must ensure an identical delegate would produce the same layout.
/// If your delegate takes arguments also make sure [shouldRelayout] and/or
/// [shouldRepaint] return true when those fields change.
///
/// A single delegate can be used by multiple widgets at a time and should not
/// keep any state. If you need to pass information from [layout] to another
/// method, store it in [layoutData] or [BoxyChild.parentData].
///
/// Delegates may access their children by name with [getChild], alternatively
/// they can be accessed through the [children] list.
///
/// The default constructor accepts [Listenable]s that can trigger re-layout and
/// re-paint. It's much more efficient for the boxy to listen directly to
/// animations than rebuilding the [CustomBoxy] with a new delegate each frame.
///
/// ## Layout
///
/// Override [layout] to control the layout of children and return what size
/// the boxy should be.
///
/// This method should call [BoxyChild.layout] for each child. It should also
/// specify the position of each child with [BoxyChild.position].
///
/// If the delegate does not depend on the size of a particular child, pass
/// `useSize: false` to [BoxyChild.layout], this prevents a change in the
/// child's size from causing a re-layout.
///
/// The following example lays out two children like a column where the second
/// widget is the same width as the first:
///
/// ```dart
///   @override
///   Size layout() {
///     // Get both children by a Symbol id
///     var firstChild = getChild(#first);
///     var secondChild = getChild(#second);
///
///     // Lay out the first child with the incoming constraints
///     var firstSize = firstChild.layout(constraints);
///     firstChild.position(Offset.zero);
///
///     // Lay out the second child
///     var secondSize = secondChild.layout(
///       constraints.deflate(
///         // Subtract height consumed by the first child from the constraints
///         EdgeInsets.only(top: firstSize.height),
///       ).tighten(
///         // Force width to be the same as the first child
///         width: firstSize.width,
///       )
///     );
///
///     // Position the second child below the first
///     secondChild.position(Offset(0, firstSize.height));
///
///     // Calculate the total size based both child sizes
///     return Size(
///       firstSize.width,
///       firstSize.height + secondSize.height,
///     );
///   }
/// ```
///
/// ## Painting
///
/// Override [paint] to draw behind children, this is similar to
/// [CustomPainter.paint] which gives you a [Canvas].
///
/// The following example simply gives the widget a blue background:
///
/// ```dart
///   @override
///   void paint() {
///     canvas.drawRect(
///       Offset.zero & render.size,
///       Paint()..color = Colors.blue,
///     );
///   }
/// ```
///
/// You can draw above children similarly by overriding [paintForeground].
///
/// Override [paintChildren] to change how children themselves are painted, for
/// example changing the order or adding [layers].
///
/// The default behavior is to paint children at the [BoxyChild.offset] given to
/// them during [layout].
///
/// The [canvas] available to [paintChildren] is not transformed implicitly like
/// [paint] and [paintForeground], implementers of this method should draw at
/// [paintOffset] and restore the canvas before painting a child. This is
/// required by the framework because a child might need to insert its own
/// compositing [Layer] between two other [PictureLayer]s.
///
/// The following example draws a semi transparent rectangle between two
/// children:
///
/// ```dart
///   @override
///   void paintChildren() {
///     getChild(#first).paint();
///     canvas.drawRect(
///       paintOffset & render.size,
///       Paint()..color = Colors.blue.withOpacity(0.3),
///     );
///     getChild(#second).paint();
///   }
/// ```
///
/// ### Layers
///
/// In order to apply special effects to children such as transforms, opacity,
/// clipping, etc. delegates will need to interact with the compositing tree.
/// Boxy wraps this functionality conveniently with [layers].
///
/// Before a delegate can push layers make sure to override [needsCompositing].
/// This getter can check the fields of the boxy to determine if compositing
/// will be necessary, return true if that is the case.
///
/// The following example paints its child with 50% opacity:
///
/// ```dart
///   @override
///   bool get needsCompositing => true;
///
///   @override
///   void paintChildren() {
///     layers.opacity(
///       opacity: 0.5,
///       paint: () {
///         getChild(#first).paint();
///       },
///     );
///   }
/// ```
///
/// ## Widget inflation
///
/// One of the most powerful features of the boxy library is to inflate
/// arbitrary widgets at layout time, this would otherwise be extraordinarily
/// difficult to implement in Flutter.
///
/// In [layout] delegates can inflate arbitrary widgets using the [inflate]
/// method, this enables complex layouts where the contents of widgets change
/// depending on the size and orientation of others, in addition to
/// [constraints].
///
/// After calling this method the child becomes available in [children] and
/// any following painting and hit testing, it is removed from the list before
/// the next [layout].
///
/// Unlike children explicitly passed to [CustomBoxy], [Key]s are not managed for
/// widgets inflated during layout, this means a widgets state is preserved if
/// inflated again with the same object id, rather than equal [Key]s.
///
/// The following example displays a text widget describing the size of another
/// child:
///
/// ```dart
///   @override
///   Size layout() {
///     var firstChild = getChild(#first);
///
///     var firstSize = firstChild.layout(constraints);
///     firstChild.position(Offset.zero);
///
///     var text = Padding(child: Text(
///       "^ This guy is ${firstSize.width} x ${firstSize.height}",
///       textAlign: TextAlign.center,
///     ), padding: EdgeInsets.all(8));
///
///     // Inflate the text widget
///     var secondChild = inflate(text, id: #second);
///
///     var secondSize = secondChild.layout(
///       constraints.deflate(
///         EdgeInsets.only(top: firstSize.height)
///       ).tighten(
///         width: firstSize.width
///       )
///     );
///
///     secondChild.position(Offset(0, firstSize.height));
///
///     return Size(
///       firstSize.width,
///       firstSize.height + secondSize.height,
///     );
///   }
/// ```
class BoxyDelegate<LayoutData extends Object> extends BaseBoxyDelegate<LayoutData, BoxyChild> {
  /// Constructs a BoxyDelegate with optional [relayout] and [repaint]
  /// [Listenable]s.
  BoxyDelegate({
    Listenable? relayout,
    Listenable? repaint,
  }) : super(
    relayout: relayout,
    repaint: repaint,
  );

  /// The current hit test result, should only be accessed from [hitTest].
  HitTestResult get hitTestResult {
    assert(() {
      if (debugPhase != BoxyDelegatePhase.hitTest) {
        throw FlutterError(
            'The $this boxy attempted to get the hit test result outside of the hitTest method.'
        );
      }
      return true;
    }());
    return render.hitTestResult!;
  }

  @override
  _RenderBoxy get render => super.render as _RenderBoxy;

  /// A list of each [BoxyChild] handle associated with the boxy, the list
  /// itself should not be modified by the delegate.
  @override
  List<BoxyChild> get children {
    var out = render.childHandles;
    assert(() {
      out = UnmodifiableListView(out);
      return true;
    }());
    return out;
  }

  /// The most recent constraints given to this boxy by its parent.
  ///
  /// During a dry layout, this returns the last constraints given to the boxy's
  /// [RenderBox.getDryLayout].
  BoxConstraints get constraints {
    final render = this.render;
    return render._dryConstraints ?? render.constraints;
  }

  /// Whether or not this boxy is performing a dry layout.
  bool get isDryLayout => render.isDryLayout;

  /// Override this method to lay out children and return the final size of the
  /// boxy.
  ///
  /// This method should call [BoxyChild.layout] for each child. It should also
  /// specify the position of each child with [BoxyChild.position].
  ///
  /// Unlike [MultiChildLayoutDelegate] the resulting size can depend on both
  /// child layouts and incoming [constraints].
  ///
  /// The default behavior is to pass incoming constraints to children and size
  /// to the largest dimensions, or the smallest size if there are no children.
  ///
  /// During a dry layout this method is called like normal, but methods like
  /// [BoxyChild.position] and [BoxyChild.layout] no longer not affect their
  /// actual orientation. Additionally, the [inflate] method will throw
  /// [CannotInflateError] if called during a dry layout.
  Size layout() {
    Size biggest = constraints.smallest;
    for (final child in children) {
      final size = child.layout(constraints);
      biggest = Size(
        max(biggest.width, size.width),
        max(biggest.height, size.height)
      );
    }
    return biggest;
  }

  /// Adds the boxy to [hitTestResult], this should typically be called from
  /// [hitTest] when a hit succeeds.
  void addHit() {
    hitTestResult.add(BoxHitTestEntry(render, render.paintOffset!));
  }

  /// Override this method to change how the boxy gets hit tested.
  ///
  /// Return true to indicate a successful hit, false to let the parent continue
  /// testing other children.
  ///
  /// Call [hitTestAdd] to add the boxy to [hitTestResult].
  ///
  /// The default behavior is to hit test all children and call [hitTestAdd] if
  /// any succeeded.
  bool hitTest(Offset position) {
    for (final child in children.reversed) {
      if (child.hitTest()) {
        addHit();
        return true;
      }
    }

    return false;
  }

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