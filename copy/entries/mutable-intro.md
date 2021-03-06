---
title: Introducing the mutable library
categories: Haskell
tags: functional programming, numerical
create-time: 2020/01/23 17:12:23
date: 2020/01/23 18:16:52
identifier: mutable-intro
slug: introducing-the-mutable-library
---

**mutable**: [documentation][mutable] / [reference][haddock] / [github][]

[mutable]: https://mutable.jle.im/
[haddock]: http://hackage.haskell.org/package/mutable
[github]: https://github.com/mstksg/mutable

I'm excited to announce the first release of the *[mutable][]* library!

The library offers what I call *beautiful mutable values*[^beautiful] ---
automatic, composable piecewise-mutable references for your data types.  Sort
of like an automatically generated `MVector`, but for all your `ADT`s.

[^beautiful]: Okay so I don't actually think the library is beautiful, I just
like the way that "beautiful mutable values" sounds when you say it out loud.

My high-level goal was a composable and overhead-free solution for dealing with
mutable values in Haskell in a type-safe and clean way.  After all, why do
imperative languages have to have all the fun?  In Haskell, we can have the
best of both worlds: efficient and clean mutable algorithms *and* type safety.

The [official documentation and homepage is here][mutable], so it's a good read
if you want to be introduced to how to use the library and where it is most
effective.  But I'm going to use this blog post to talk about *why* I wrote the
library, some of the neat things you can do with it, and the techniques that
went into writing it.

Motivation
----------

The original motivation for this comes from my development of *[backprop][]*
and *[backprop-learn][]*, as I was trying to adapt my [Functional
Models][functional-models] framework to efficient Haskell code.

[backprop]: https://backprop.jle.im/
[backprop-learn]: https://github.com/mstksg/backprop-learn
[functional-models]: https://blog.jle.im/entries/series/+functional-models.html

To properly train Artificial Neural Networks with Haskell, you need to do a lot
of independent piecewise mutations to matrices and vectors.  This becomes
inefficient, quickly, because you have to do a lot of copying in the process
for pure vectors and neural network weights.  This problem also comes up for
efficient simulations that require mutating many different components
independently under a tight loop.

### Piecewise-Mutable

First of all, what do I mean by "piecewise-mutable"?  Well, a simple example is
the mutable vector type, where piecewise-mutable edits are able to save a lot
of time and memory allocation.

If we want to edit the first item in a vector multiple times, this is extremely
inefficient with a pure vector:

```haskell
addFirst :: Vector Double -> Vector Double
addFirst xs = iterate incr xs !! 1000000
  where
    incr v = v V.// [(0, (v V.! 0) + 1)]
```

That's because `addFirst` will copy over the entire vector for every step
--- every single item, even if not modified, will be copied one million times.
It is $O(n*l)$ in memory updates --- it is very bad for long vectors or large
matrices.

However, this is extremely efficient with a mutable vector:

```haskell
addFirst :: Vector Double -> Vector Double
addFirst xs = runST $ do
    v <- V.thaw xs
    replicateM_ 1000000 $ do
        MV.modify v 0 (+ 1)
    V.freeze v
```

This is because all of the other items in the vector are kept the same and not
copied-over over the course of one million updates.  It is $O(n+l)$ in memory
updates.  It is very good even for long vectors or large matrices.

This situation is somewhat contrived, but it isolates a problem that many
programs face. A more common situation might be that you have two functions
that each modify different items in a vector in sequence, and you want to run
them many times interleaved, or one after the other.

### Composite Datatype

That was an example of using piecewise mutability for vectors, but it's not
exactly scalable.  That's because it always requires having a separate type for
the *pure* type and the *value* type.  We're lucky enough to have one for
`Vector`...but what about for our own custom types?  That's a lot of headache.

```haskell
data TwoVec = TV { tv1 :: Vector Double
                 , tv2 :: Vector Double
                 }
  deriving Generic
```

To use this in a "piecewise-mutable" way, we would need a separate "mutable"
version:


```haskell
data TwoVecRef s = TVR { tvr1 :: MVector s Double
                       , tvr2 :: MVector s Double
                       }
```

Then we can do things like "mutate only the first item in the first vector" a
million times, and be efficient with it.

We'd have to write functions to "thaw" and "freeze"

```haskell
thawTwoVec :: (s ~ PrimState m) => TwoVec -> m (TwoVecRef s)
thawTwoVec (TV x y) = TVR <$> V.thaw x <*> V.thaw y

freezeTwoVec :: (s ~ PrimState m) => TwoVecRef s -> m TwoVec
freezeTwoVec (TVR u v) = TV <$> V.freeze u <*> V.freze v
```

It just doesn't scale in a composable way.  You'd have to create a second
version of every data type.

### Solution

The library provides the `Mutable` typeclass and the `GRef` type, where `GRef m
X` is the automatically derived piecewise-mutable version of `X`.

```haskell
instance PrimMonad m => Mutable m TwoVec where
    type Ref m TwoVec = GRef m TwoVec
```

The type `GRef m TwoVec` is *exactly* the `TwoVecRef` that we defined earlier:
it is a tuple of two `MVector`s.  It can do this because `Vector` itself has a
`Mutable` instance, where its mutable version is `MVector`.  `GRef m TwoVec` is
essentially the "MVector" of `TwoVec`.

This now gives us `thawRef :: TwoVec -> m (GRef m TwoVec)` and `freezeRef ::
GRef m TwoVec -> m TwoVec`, for free, so we can write:

```haskell
addFirst :: TwoVec -> TwoVec
addFirst xs = runST $ do
    v <- thawRef xs
    replicateM_ 1000000 $ do
      withField #tv1 v $ \u ->
        MV.modify u 0 (+ 1)
    freezeRef v
```

This will in-place edit only the first item in the `tv1` field one million
times, without ever needing to copy over the contents `tv2`.  Basically, it
gives you a version of `TwoVec`  that you can modify in-place piecewise.  You
can compose two functions that each work piecewise on `TwoVec`:

```haskell
mut1 :: PrimMonad m => Ref m TwoVec -> m ()
mut1 v = do
    withField #tv1 v $ \u ->
      MV.modify u 0 (+ 1)
      MV.modify u 1 (+ 2)
    withField #tv2 v $ \u ->
      MV.modify u 2 (+ 3)
      MV.modify u 3 (+ 4)

mut2 :: PrimMonad m => Ref m TwoVec -> m ()
mut2 v = do
    withField #tv1 v $ \u ->
      MV.modify u 4 (+ 1)
      MV.modify u 5 (+ 2)
    withField #tv2 v $ \u ->
      MV.modify u 6 (+ 3)
      MV.modify u 7 (+ 4)

doAMillion :: TwoVec -> TwoVec
doAMillion xs = runST $ do
    v <- thawRef xs
    replicateM_ 1000000 $ do
      mut1 v
      mut2 v
    freezeRef v
```

The end result?  You can now modify only a single component of your large
composite data type (and even single items in vectors in them) without making
nested copies every time.

Neat Consequences
-----------------

### Mutable Sum Types

While developing the library, I accidentally also stumbled into a way of
automatically deriving useful mutable sum types and data structures in Haskell.
This was more or less a complete accident --- I was writing the code to
automatically generate `GRef`, and needed to account for sum types somehow.
The result was actually useful!

For example, it is a publicly kept secret that Haskell's list type --- "linked
lists", are actually very different from the [mutable linked lists][mll]
encountered as a standard data structure in languages like Java and C++.  As it
turns out, using `GRef m [a]` gives us exactly the mutable linked list type ...
for free!

[mll]: https://en.wikipedia.org/wiki/Linked_list

```haskell
data List a = Nil | Cons a (List a)
  deriving (Show, Generic)
infixr 5 `Cons`

instance (Mutable m a, PrimMonad m) => Mutable m (List a) where
    type Ref m (List a) = GRef m (List a)
```

Here we are re-implementing the `List` data structure from scratch just to show
that there is nothing arbitrary going on with the default list --- it works for
any appropriately defined ADT.  We could even do binary trees!

Right away we can write functions to flesh out the API for a mutable linked
list.  For example, a function to check if a linked list is empty:

```haskell
-- | Check if a mutable linked list is currently empty
isEmpty
    :: (PrimMonad m, Mutable m a)
    => Ref m (List a)
    -> m Bool
isEmpty = hasBranch (constrMB #_Nil)
```

Here is a function to "pop" a mutable linked list, giving us the first value
and shifting the rest of the list up.

```haskell
popStack
    :: (PrimMonad m, Mutable m a)
    => Ref m (List a)
    -> m (Maybe a)
popStack xs = do
    c <- projectBranch (constrMB #_Cons) xs
    forM c $ \(y, ys) -> do
      o <- freezeRef y
      moveRef xs ys
      pure o
```

And a function to concatenate a second linked list to the end of a first one:

```haskell
concatLists
    :: (PrimMonad m, Mutable m a)
    => Ref m (List a)
    -> Ref m (List a)
    -> m ()
concatLists l1 l2 = do
    c <- projectBranch consBranch l1
    case c of
      Nothing      -> moveRef l1 l2
      Just (_, xs) -> concatLists xs l2
```

### Higher-Kinded Data

I'm rather enamoured by the "[higher-kinded data][hkd]" pattern made popular by
Sandy Maguire.  It essentially eliminates the need for explicit getters and
setters by making the data type *itself* the thing that offers what you want,
and you can get at it by just pattern matching.

[hkd]: https://reasonablypolymorphic.com/blog/higher-kinded-data/

Because of this, if your data type is written in the "higher-kinded data"
pattern, then `MyType f` doubles as both the pure type *and* the mutable
type, just by choice of `f`.  `MyTypeF Identity` would be the pure version, and
`MyTypeF (RefFor m)` would be the mutable version.

```haskell
data MyTypeF f = MTF
    { mtfInt    :: HKD f Int
    , mtfDouble :: HKD f Double
    , mtfVec    :: HKD f (V.Vector Double)
    }
  deriving Generic

type MyType' = MyTypeF Identity

instance PrimMonad m => Mutable m MyType' where
    type Ref m MyType' = MyTypeF (RefFor m)
```

We can directly use it like a normal data type:

```haskell
MTF 3 4.5 (V.fromList [1..100])
    :: MyType'
```

But now, `MyTypeF (RefFor m)` literally has mutable references as its fields.
You can pattern match to get `rI :: MutVar s Int`, `rD :: MutVar s Double`, and
`rV :: MVector s Double`

```haskell
MTF rI rD rV :: MyTypeF (RefFor m)
```

and the accessors work as well:

```haskell
mtfVec
    :: (s ~ PrimState m)
    -> MyTypeF (RefFor m)
    -> MVector s Double
```

You can use it like:

```haskell
runST $ do
    r@(MTF rI rD rV) <- thawRef $ MTF 0 19.3 (V.fromList [1..10])

    replicateM_ 1000 $ do

        -- rI is just the 'Int' ref
        modifyMutVar rI (+ 1)

        -- rV is the 'MVector'
        MV.modify rV (+1) 0

    freezeRef r

-- => MTF 1000 19.3 [1001.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
```

The "mutable version" of a type literally *is* the ADT, if you use the
higher-kinded data pattern!

Reflections on Generic
----------------------

This library is pretty much powered 95% by GHC Generics, as the name `GRef`
implies.  GHC Generics is probably one of the single most powerful tools we
have in Hasekll-the-language for writing typesafe abstractions and eliminating
all the boilerplate.

The structure of the `GRef` data type is completely determined by using the
*GHC.Generics* `Rep` of an algebraic data type with a `Generic` instance.  It
breaks apart the products and sums and turns them into the mutable references
you *would* normally write by hand.

Writing `GRef` itself was actually very pleasant: it just involves matching up
generic pieces with the references they represent.  "What is the reference for
a constant value?  What is the reference for a product type?  What is the
reference for a sum type?"  And, in the process of answering those questions, I
ended up discovering something new (as shown in the section above about mutable
linked lists).

Generics also powers the *higher-kinded data* based systems, which can add a
lot of syntactic niceness to everything if you decide to use it.

Still, I understand not everyone wants to restructure their data types in terms
of higher-kinded data ... there are a lot of practical issues to doing so, and
it doesn't really work well with nested data types.  For that, I turned to
*[generic-lens][]*.

[generic-lens]: https://hackage.haskell.org/package/generic-lens

*generic-lens* is what powers the OverloadedLabels-based field accessor methods
that let you work with `GRef`s in a seamless way, by being able to do
`withField #blah`, etc., instead of having to directly match on the `GRef`
value's internal contents (which can be messy, admittedly).  It also allows you
to do `withPos @2` to get the second item in your `GRef`, and `withTuple` to
allow you to get the mutable fields in your data type as a tuple.

I was originally going to implement the field accessors myself, looking to
*generic-lens* for inspiration.  However, when I looked at the library's
internals, I realized there was a lot more going on than I had originally
thought.  But, looking at what was exported, I realized that the library was
well-designed enough that I could actually directly use its generic
implementations for *mutable*!  As a result, the field/position/tuple accessor
code actually required no mucking around with generics at all --- I could
leverage *generic-lens*, which was powerful enough to allow me to eliminate all
of my generics code.

I strongly recommend anyone looking to do things involving generic access to
fields to look at *generic-lens* to see if it can eliminate all your generics
code as well!

Unfortunately, I wasn't able to re-use the code for the "constructor" access
(as seen with `constrMB #_Cons` earlier) --- but I could use it as inspiration
to write my own.  The library offers a very clean and well-written pattern to
doing things like this that I probably would have spent a long time trying to
figure out, if I had to do it from scratch.

Next Steps
----------

I learned a lot from GHC Generics writing this library --- in a sense, the
library is pretty much completely an application of GHC Generics, without much
new concepts beyond that.

My next step is to equip *backprop* to use `Mutable` instead of its `Backprop`
typeclass, so it can do in-place mutation of composite data types for much
faster backpropagation.

However, my newly gained experience with generics from writing this library can
actually do a lot to improve the ergonomics of *backprop* as well --- in
particular, with `BVar`, which has always been very annoying to work with, even
with the lens-based API offered.  Working with a `BVar` as if it were a normal
value has always been annoying, especially with product types.  There are a lot
of ways GHC generics can help this, that I am now only learning about.  Check
back soon --- hopefully I'll have something to show by then.

Until then, happy mutating!  And please let me know if you find any interesting
applications of the library :D

