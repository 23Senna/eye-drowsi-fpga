import unittest
import numpy as np
from check_crops import match_train, TRAIN_MEAN, TRAIN_STD


class MatchTrainTest(unittest.TestCase):
    def test_bright_crop_moves_to_training_statistics(self):
        rng = np.random.default_rng(1)
        crop = np.clip(rng.normal(124, 19, (24, 24)), 60, 235).astype(np.uint8)
        out = match_train(crop)
        self.assertEqual((out.dtype, out.shape), (np.uint8, (24, 24)))
        self.assertAlmostEqual(out.mean(), TRAIN_MEAN, delta=1.0)
        self.assertAlmostEqual(out.std(), TRAIN_STD, delta=1.0)
        self.assertEqual(len(out.tobytes()), 576)

    def test_flat_crop_stays_valid(self):
        out = match_train(np.full((24, 24), 200, np.uint8))
        self.assertTrue((out == round(TRAIN_MEAN)).all())


if __name__ == '__main__':
    unittest.main()
