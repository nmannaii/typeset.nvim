//! A minimal typst `World`: one in-memory main file, extra in-memory files (diagram SVGs),
//! and the fonts embedded by typst-assets. Nothing is read from disk or the network, which is
//! what keeps the renderer standalone.

use std::collections::HashMap;
use std::sync::LazyLock;

use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};

struct Fonts {
    book: LazyHash<FontBook>,
    fonts: Vec<Font>,
}

/// Sans-serif for diagrams and UI-ish text; typst-assets only ships serif and mono.
pub const INTER_REGULAR: &[u8] = include_bytes!("../fonts/Inter-Regular.ttf");
const INTER: [&[u8]; 4] = [
    INTER_REGULAR,
    include_bytes!("../fonts/Inter-Bold.ttf"),
    include_bytes!("../fonts/Inter-Italic.ttf"),
    include_bytes!("../fonts/Inter-SemiBold.ttf"),
];

static FONTS: LazyLock<Fonts> = LazyLock::new(|| {
    let fonts: Vec<Font> = typst_assets::fonts()
        .chain(INTER)
        .flat_map(|data| Font::iter(Bytes::new(data)))
        .collect();
    Fonts { book: LazyHash::new(FontBook::from_fonts(&fonts)), fonts }
});

static LIBRARY: LazyLock<LazyHash<Library>> = LazyLock::new(|| LazyHash::new(Library::default()));

/// Typst sources compiled into the binary: the mitex scope that its LaTeX → typst math
/// conversion refers to (mitexsqrt, pmatrix, textmath, ...), from the mitex typst package.
const EMBEDDED_SOURCES: [(&str, &str); 3] = [
    ("/mitex/specs/mod.typ", include_str!("../typst/mitex/specs/mod.typ")),
    ("/mitex/specs/prelude.typ", include_str!("../typst/mitex/specs/prelude.typ")),
    ("/mitex/specs/latex/standard.typ", include_str!("../typst/mitex/specs/latex/standard.typ")),
];

static EMBEDDED: LazyLock<HashMap<FileId, Source>> = LazyLock::new(|| {
    EMBEDDED_SOURCES.iter().map(|(path, text)| (file_id(path), Source::new(file_id(path), text.to_string()))).collect()
});

pub fn file_id(path: &str) -> FileId {
    RootedPath::new(VirtualRoot::Project, VirtualPath::new(path).expect("valid virtual path")).intern()
}

pub struct MemoryWorld {
    main: Source,
    files: HashMap<FileId, Bytes>,
}

impl MemoryWorld {
    pub fn new(text: String, files: HashMap<String, Vec<u8>>) -> Self {
        Self {
            main: Source::new(file_id("/main.typ"), text),
            files: files.into_iter().map(|(path, data)| (file_id(&path), Bytes::new(data))).collect(),
        }
    }
}

impl World for MemoryWorld {
    fn library(&self) -> &LazyHash<Library> {
        &LIBRARY
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &FONTS.book
    }

    fn main(&self) -> FileId {
        self.main.id()
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if id == self.main.id() {
            Ok(self.main.clone())
        } else {
            EMBEDDED.get(&id).cloned().ok_or_else(|| FileError::NotFound(Default::default()))
        }
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        self.files.get(&id).cloned().ok_or_else(|| FileError::NotFound(Default::default()))
    }

    fn font(&self, index: usize) -> Option<Font> {
        FONTS.fonts.get(index).cloned()
    }

    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> {
        None
    }
}
