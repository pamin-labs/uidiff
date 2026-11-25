"""Check that README image links are portable and resolve within a checkout."""

from pathlib import Path
import runpy
from tempfile import TemporaryDirectory
import unittest


check = runpy.run_path(str(Path(__file__).with_name("readme-images.py")))["check"]


class ReadmeImageTests(unittest.TestCase):
    def test_image_links_stay_inside_the_checkout(self):
        with TemporaryDirectory() as directory:
            parent = Path(directory)
            checkout = parent / "checkout"
            checkout.mkdir()
            image = checkout / "sample.png"
            image.touch()
            outside = parent / "outside.png"
            outside.touch()
            readme = checkout / "README.md"
            readme.write_text('![Example](sample.png)\n<img src="sample.png">\n')
            check(checkout)

            for link in ("../outside.png", image.as_posix()):
                with self.subTest(link=link):
                    readme.write_text(f"![Example]({link})")
                    with self.assertRaisesRegex(SystemExit, "expected a relative image in the checkout"):
                        check(checkout)


if __name__ == "__main__":
    unittest.main()
