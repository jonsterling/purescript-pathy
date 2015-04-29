module Data.Path.Pathy
  ( Abs()
  , AbsDir(..)
  , AbsFile(..)
  , Dir()
  , DirName(..)
  , Escaper(..)
  , File()
  , FileName(..)
  , Path()
  , Rel()
  , RelDir(..)
  , RelFile(..)
  , Sandboxed()
  , Unsandboxed()
  , (</>)
  , (<.>)
  , canonicalize
  , changeExtension
  , currentDir
  , dir
  , dir'
  , dirName
  , dropExtension
  , extension
  , file 
  , file'
  , fileName
  , identicalPath
  , isAbsolute
  , isRelative
  , parentDir
  , parentDir'
  , peel
  , posixEscaper
  , parsePath
  , parseAbsDir
  , parseAbsFile
  , parseRelDir
  , parseRelFile
  , printPath
  , printPath'
  , refine
  , relativeTo
  , renameDir
  , renameFile
  , rootDir
  , runEscaper
  , sandbox
  , unsandbox
  , unsafePrintPath
  , unsafePrintPath'
  )
  where

  import Control.Alt((<|>))
  import qualified Data.String as S
  import Data.Foldable(foldr)
  import Data.Array(filter, length, zipWith, range)
  import Data.Tuple(Tuple(..), fst, snd)
  import Data.Either(Either(..), either)
  import Data.Maybe(Maybe(..), maybe, fromMaybe)
  import Data.List(List(..))
  import Data.Profunctor.Strong(first)
    
  -- | The (phantom) type of relative paths.
  foreign import data Rel :: *

  -- | The (phantom) type of absolute paths.
  foreign import data Abs :: *

  -- | The (phantom) type of files.
  foreign import data File :: *

  -- | The (phantom) type of directories.
  foreign import data Dir :: *

  -- | The (phantom) type of unsandboxed paths.
  foreign import data Unsandboxed :: *

  -- | The (phantom) type of sandboxed paths.
  foreign import data Sandboxed :: *

  -- | A newtype around a file name.
  newtype FileName = FileName String

  -- | A newtype around a directory name.
  newtype DirName = DirName  String

  -- | A type that describes a Path. All flavors of paths are described by this 
  -- | type, whether they are absolute or relative paths, whether they 
  -- | refer to files or directories, whether they are sandboxed or not.
  -- | 
  -- | * The type parameter `a` describes whether the path is `Rel` or `Abs`.
  -- | * The type parameter `b` describes whether the path is `File` or `Dir`.
  -- | * The type parameter `s` describes whether the path is `Sandboxed` or `Unsandboxed`.
  -- |
  -- | To ensure type safety, there is no way for users to create a value of 
  -- | this type directly. Instead, helpers should be used, such as `rootDir`,
  -- | `currentDir`, `file`, `dir`,  `(</>)`, and `parsePath`.
  -- | 
  -- | This ADT allows invalid paths (e.g. paths inside files), but there is no
  -- | possible way for such paths to be constructed by user-land code. The only
  -- | "invalid path" that may be constructed is using the `parentDir'` function, e.g.
  -- | `parentDir' rootDir`, or by parsing an equivalent string such as `/../`, 
  -- | but such paths are marked as unsandboxed, and may not be rendered to strings
  -- | until they are first sandboxed to some directory.
  data Path a b s = Current | Root | ParentIn (Path a b s) | DirIn (Path a b s) DirName | FileIn (Path a b s) FileName

  -- | A type describing a file whose location is given relative to some other,
  -- | unspecified directory (referred to as the "current directory").
  type RelFile s = Path Rel File s

  -- | A type describing a file whose location is absolutely specified.
  type AbsFile s = Path Abs File s

  -- | A type describing a directory whose location is given relative to some 
  -- | other, unspecified directory (referred to as the "current directory").
  type RelDir s = Path Rel Dir s

  -- | A type describing a directory whose location is absolutely specified.
  type AbsDir s = Path Abs Dir s

  -- | Escapers encode segments or characters which have reserved meaning.
  newtype Escaper = Escaper (String -> String)

  -- | Given an escaper and a segment to encode, returns the encoded segment.
  runEscaper :: Escaper -> String -> String
  runEscaper (Escaper f) = f

  -- | An escaper that does nothing except remove slashes (the bare minimum of
  -- | what must be done).
  nonEscaper :: Escaper
  nonEscaper = Escaper $ \s -> S.joinWith "" $ filter ((/=) "/") (S.split "" s)

  -- | An escaper that removes all slashes, converts ".." into "$dot$dot", and
  -- | converts "." into "$dot".
  posixEscaper :: Escaper
  posixEscaper = Escaper $ runEscaper nonEscaper >>> \s -> if s == ".." then "$dot$dot" else if s == "." then "$dot" else s

  -- | Creates a path which points to a relative file of the specified name.
  file :: forall s. String -> Path Rel File s
  file f = file' (FileName f)

  -- | Creates a path which points to a relative file of the specified name.
  file' :: forall s. FileName -> Path Rel File s
  file' f = FileIn Current f

  -- | Retrieves the name of a file path.
  fileName :: forall a s. Path a File s -> FileName
  fileName (FileIn _ f) = f
  fileName _            = FileName ""

  -- | Retrieves the extension of a file name.
  extension :: FileName -> String
  extension (FileName f) = let idx = S.lastIndexOf "." f in if idx == -1 then "" else S.drop (idx + 1) f

  -- | Drops the extension on a file name.
  dropExtension :: FileName -> FileName
  dropExtension (FileName n) = 
    let idx = S.lastIndexOf "." n
    in if idx == -1 then FileName n else FileName $ S.take idx n

  -- | Changes the extension on a file name.
  changeExtension :: forall a s. (String -> String) -> FileName -> FileName
  changeExtension f nm @ (FileName n) = 
    let 
      ext = f $ extension nm
    in (\(FileName n) -> if ext == "" then FileName n else FileName $ n ++ "." ++ ext) (dropExtension nm)

  -- | Retrieves the name of a directory path. Not all paths have such a name, 
  -- | for example, the root or current directory.
  dirName :: forall a s. Path a Dir s -> Maybe DirName 
  dirName p = case canonicalize p of 
    (DirIn _ d) -> Just d
    _           -> Nothing

  -- | Creates a path which points to a relative directory of the specified name.
  dir :: String -> Path Rel Dir Sandboxed 
  dir d = dir' (DirName d)

  -- | Creates a path which points to a relative directory of the specified name.
  dir' :: forall s. DirName -> Path Rel Dir s
  dir' d = DirIn Current d

  -- | Given a directory path, appends either a file or directory to the path.
  (</>) :: forall a b s. Path a Dir s -> Path Rel b s -> Path a b s
  (</>) (Current       ) (Current       ) = Current
  (</>) (Root          ) (Current       ) = Root
  (</>) (ParentIn p1   ) (Current       ) = ParentIn (p1      </> Current)
  (</>) (FileIn   p1 f1) (Current       ) = FileIn   (p1      </> Current) f1
  (</>) (DirIn    p1 d1) (Current       ) = DirIn    (p1      </> Current) d1
  (</>) (Current       ) (Root          ) = Current                           -- doesn't make sense but cannot exist
  (</>) (Root          ) (Root          ) = Root                              -- doesn't make sense but cannot exist
  (</>) (ParentIn p1   ) (Root          ) = ParentIn (p1      </> Current)    -- doesn't make sense but cannot exist
  (</>) (FileIn   p1 f1) (Root          ) = FileIn   (p1      </> Current) f1 -- doesn't make sense but cannot exist
  (</>) (DirIn    p1 d1) (Root          ) = DirIn    (p1      </> Current) d1 -- doesn't make sense but cannot exist
  (</>) (p1            ) (ParentIn p2   ) = ParentIn (p1      </> p2     )
  (</>) (p1            ) (FileIn   p2 f2) = FileIn   (p1      </> p2     ) f2
  (</>) (p1            ) (DirIn    p2 d2) = DirIn    (p1      </> p2     ) d2

  -- | Sets the extension of the file to the specified extension.
  -- |
  -- | ```purescript
  -- | file "image" <.> "png"
  -- | ```
  (<.>) :: forall a s. Path a File s -> String -> Path a File s
  (<.>) p ext = renameFile (changeExtension $ const ext) p

  -- | Determines if this path is absolutely located.
  isAbsolute :: forall a b s. Path a b s -> Boolean
  isAbsolute (Current     ) = false
  isAbsolute (Root        ) = true
  isAbsolute (ParentIn p  ) = isAbsolute p
  isAbsolute (FileIn   p _) = isAbsolute p
  isAbsolute (DirIn    p _) = isAbsolute p

  -- | Determines if this path is relatively located.
  isRelative :: forall a b s. Path a b s -> Boolean
  isRelative p = not $ isAbsolute p

  -- | Peels off the last directory and the terminal file or directory name 
  -- | from the path. Returns `Nothing` if there is no such pair (for example, 
  -- | if the last path segment is root directory, current directory, or parent 
  -- | directory).
  peel :: forall a b s. Path a b s -> Maybe (Tuple (Path a Dir s) (Either DirName FileName))
  peel (Current     ) = Nothing
  peel (Root        ) = Nothing
  peel (ParentIn p  ) = peel p >>= (fst >>> peel)
  peel (DirIn    p d) = Just $ maybe (if isAbsolute p then Tuple Root d' else Tuple Current d') 
                                     (\(Tuple p e) -> Tuple (either (DirIn p) (FileIn p) e) d') (peel p)
                          where d' = Left d
  peel (FileIn   p f) = Just $ maybe (if isAbsolute p then Tuple Root f' else Tuple Current f') 
                                     (\(Tuple p e) -> Tuple (either (DirIn p) (FileIn p) e) f') (peel p)
                          where f' = Right f

  -- | Attempts to extract out the parent directory of the specified path. If the 
  -- | function would have to use a relative path in the return value, the function will
  -- | instead return `Nothing`.
  parentDir :: forall a b s. Path a b s -> Maybe (Path a Dir s)
  parentDir p = fst <$> peel p

  -- | Unsandboxes any path (whether sandboxed or not).
  unsandbox :: forall a b s. Path a b s -> Path a b Unsandboxed 
  unsandbox (Current     ) = Current
  unsandbox (Root        ) = Root
  unsandbox (ParentIn p  ) = ParentIn (unsandbox p)
  unsandbox (DirIn    p d) = DirIn    (unsandbox p) d
  unsandbox (FileIn   p f) = FileIn   (unsandbox p) f  

  -- | Extracts out the parent directory of the specified path. Will use the 
  -- | parent path segment (..) if strictly necessary and therefore can escape 
  -- | a sandboxed path.
  parentDir' :: forall a b s. Path a b s -> Path a Dir Unsandboxed 
  parentDir' (Current     ) = ParentIn Current
  parentDir' (Root        ) = ParentIn Root
  parentDir' (ParentIn p  ) = ParentIn (parentDir' p)
  parentDir' (FileIn   p f) = maybe (if isAbsolute p then Root else Current) 
                                    (\(Tuple p e) -> either (DirIn p) (FileIn p) e) (first unsandbox <$> peel p)
  parentDir' (DirIn    p f) = maybe (if isAbsolute p then Root else Current) 
                                    (\(Tuple p e) -> either (DirIn p) (FileIn p) e) (first unsandbox <$> peel p)

    -- | The "current directory", which can be used to define relatively-located resources.
  currentDir :: Path Rel Dir Sandboxed 
  currentDir = Current

  -- | The root directory, which can be used to define absolutely-located resources.
  rootDir :: Path Abs Dir Sandboxed 
  rootDir = Root

  -- | Renames a file path.
  renameFile :: forall a s. (FileName -> FileName) -> Path a File s -> Path a File s
  renameFile f = go 
    where
      go (FileIn p f0) = FileIn p (f f0)
      go (p          ) = p

  -- | Renames a directory path. Note: This is a simple rename of the terminal 
  -- | directory name, not a "move".
  renameDir :: forall a s. (DirName -> DirName) -> Path a Dir s -> Path a Dir s
  renameDir f = go
    where 
      go (DirIn p d) = DirIn p (f d)
      go (p        ) = p

  -- | Canonicalizes a path, by reducing things in the form `/x/../` to just `/x/`.
  canonicalize :: forall a b s. Path a b s -> Path a b s
  canonicalize p = snd $ canonicalize' p

  -- | Canonicalizes a path and returns information on whether or not it actually changed.
  canonicalize' :: forall a b s. Path a b s -> Tuple Boolean (Path a b s)
  canonicalize' (Current              ) = Tuple false Current 
  canonicalize' (Root                 ) = Tuple false Root
  canonicalize' (ParentIn (FileIn p f)) = Tuple true p
  canonicalize' (ParentIn (DirIn  p f)) = Tuple true p
  canonicalize' (ParentIn (p         )) = (\(Tuple changed p') -> 
                                          let p'' = ParentIn p' in if changed then canonicalize' p'' else Tuple changed p'') $ canonicalize' p
  canonicalize' (FileIn   p f         ) = flip FileIn f <$> canonicalize' p
  canonicalize' (DirIn    p d         ) = flip DirIn  d <$> canonicalize' p

  unsafePrintPath' :: forall a b s. Escaper -> Path a b s -> String
  unsafePrintPath' r p = go p
    where  
      go (Current)                                  = "./"
      go (Root)                                     = "/"
      go (ParentIn p)                               = go p ++ "../"
      go (DirIn    p @ (FileIn _ _ )   (DirName d)) = go p ++ "/" ++ d ++ "/" -- dir inside a file
      go (DirIn    p   (DirName                 d)) = go p ++ d ++ "/"        -- dir inside a dir
      go (FileIn   p @ (FileIn  _ _)  (FileName f)) = go p ++ "/" ++ f        -- file inside a file
      go (FileIn   p   (FileName                f)) = go p ++ f  

  unsafePrintPath :: forall a b s. Path a b s -> String
  unsafePrintPath = unsafePrintPath' posixEscaper

  -- | Prints a `Path` into its canonical `String` representation. For security 
  -- | reasons, the path must be sandboxed before it can be rendered to a string.
  printPath :: forall a b. Path a b Sandboxed -> String
  printPath = unsafePrintPath

  -- | Prints a `Path` into its canonical `String` representation, using the 
  -- | specified escaper to escape special characters in path segments. For 
  -- | security reasons, the path must be sandboxed before rendering to string.
  printPath' :: forall a b. Escaper -> Path a b Sandboxed -> String
  printPath' = unsafePrintPath'

  -- | Determines if two paths have the exact same representation. Note that 
  -- | two paths may represent the same path even if they have different 
  -- | representations!
  identicalPath :: forall a a' b b' s s'. Path a b s -> Path a' b' s' -> Boolean 
  identicalPath p1 p2 = show p1 == show p2

  -- | Makes one path relative to another reference path, if possible, otherwise 
  -- | returns `Nothing`. The returned path inherits the sandbox settings of the 
  -- | reference path.
  -- | 
  -- | Note there are some cases this function cannot handle. 
  relativeTo :: forall a b s s'. Path a b s -> Path a Dir s' -> Maybe (Path Rel b s')
  relativeTo p1 p2 = relativeTo' (canonicalize p1) (canonicalize p2) where
    relativeTo' :: forall a b s s'. Path a b s -> Path a Dir s' -> Maybe (Path Rel b s')
    relativeTo' p1 p2 = 
      if identicalPath p1 p2 then Just Current else case peel p1 of
        Nothing            -> case Tuple p1 p2 of 
                                Tuple Root    Root    -> Just Current 
                                Tuple Current Current -> Just Current 
                                _                     -> Nothing
        Just (Tuple p1' e) -> flip (</>) (either (DirIn Current) (FileIn Current) e) <$> relativeTo' p1' p2

  -- | Attempts to sandbox a path relative to some directory. If successful, the sandboxed 
  -- | directory will be returned relative to the sandbox directory (although this can easily
  -- | be converted into an absolute path using `</>`).
  -- | 
  -- | This combinator can be used to ensure that paths which originate from user-code
  -- | cannot access data outside a given directory.
  sandbox :: forall a b s. Path a Dir Sandboxed -> Path a b s -> Maybe (Path Rel b Sandboxed )
  sandbox p1 p2 = p2 `relativeTo` p1

  -- | Refines path segments but does not change anything else.
  refine :: forall a b s. (FileName -> FileName) -> (DirName -> DirName) -> Path a b s -> Path a b s
  refine f d = go
    where go (Current      ) = Current
          go (Root         ) = Root
          go (ParentIn p   ) = ParentIn (go p)
          go (DirIn    p d0) = DirIn    (go p) (d d0)
          go (FileIn   p f0) = FileIn   (go p) (f f0)

  -- | Parses a canonical `String` representation of a path into a `Path` value.
  -- | Note that in order to be unambiguous, trailing directories should be 
  -- | marked with a trailing slash character (`'/'`).
  parsePath :: forall z.
    (RelFile Unsandboxed -> z) ->
    (AbsFile Unsandboxed -> z) ->
    (RelDir  Unsandboxed -> z) ->
    (AbsDir  Unsandboxed -> z) -> String -> z
  parsePath rf af rd ad p = 
    let
      segs      = filter (\s -> S.length s > 0) (S.split "/" p)
      filename  = let i = S.lastIndexOf "/" p in if i == -1 then "" else S.drop (i + 1) p
      lastIndex = length segs - 1
      tuples    = zipWith Tuple segs (range 0 lastIndex)

      folder :: forall a b s. Tuple String Number -> (Path a b s -> Path a b s) -> (Path a b s -> Path a b s)
      folder (Tuple seg idx) f = case idx of
        idx | idx == 0  -> const $ f 
                           (if seg == "."       then Current                         else
                            if seg == ".."      then ParentIn Current                else
                            if seg == ""        then Root                            else 
                            if idx == lastIndex then FileIn Current (FileName seg)   else 
                                                     DirIn  Current (DirName  seg))
        idx             -> if seg == "."  then f                           else
                           if seg == ".." then \p -> ParentIn (f p)        else
                           if seg == ""   then f                           else 
                                               \p -> DirIn p (DirName seg)
    in 
      if p == "" then rd Current 
      else if S.take 1 p == "/" then (if filename == "" then ad (foldr folder id tuples Root) else af (foldr folder id tuples Root))
      else if filename   == ""  then rd (foldr folder id tuples Root) else rf (foldr folder id tuples Root)

  -- | Attempts to parse a relative file from a string.
  parseRelFile :: String -> Maybe (RelFile Unsandboxed)
  parseRelFile = parsePath Just (const Nothing) (const Nothing) (const Nothing)

  -- | Attempts to parse an absolute file from a string.
  parseAbsFile :: String -> Maybe (AbsFile Unsandboxed)
  parseAbsFile = parsePath (const Nothing) Just (const Nothing) (const Nothing)

  -- | Attempts to parse a relative directory from a string.
  parseRelDir :: String -> Maybe (RelDir Unsandboxed)
  parseRelDir = parsePath (const Nothing) (const Nothing) Just (const Nothing)

  -- | Attempts to parse an absolute directory from a string.
  parseAbsDir :: String -> Maybe (AbsDir Unsandboxed)
  parseAbsDir = parsePath (const Nothing) (const Nothing) (const Nothing) Just

  instance showPath :: Show (Path a b s) where
    show (Current                ) = "currentDir"
    show (Root                   ) = "rootDir"
    show (ParentIn p             ) = "(parentDir' " ++ show p ++ ")"
    show (FileIn   p (FileName f)) = show p ++ "(file " ++ f ++ ")"
    show (DirIn    p (DirName  f)) = show p ++ "(dir "  ++ f ++ ")"

  instance eqPath :: Eq (Path a b s) where
    (==) p1 p2 = canonicalize p1 == canonicalize p2

    (/=) p1 p2 = not (p1 == p2)