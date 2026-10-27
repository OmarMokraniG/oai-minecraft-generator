import io

from PIL import Image


class ImageFrameProcessor:
    def __init__(self, frames_directory="frames"):
        self.frames_directory = frames_directory

    def add_frame(self, image_bytes, frame_path):
        """
        Add a frame to an image.

        Args:
            image_bytes (io.BytesIO): The image as bytes
            frame_path (str): Path to the frame image

        Returns:
            io.BytesIO: The processed image with frame added
        """
        # Open the image bytes with PIL
        base_image = Image.open(image_bytes).convert("RGBA")

        # Open the frame
        frame = Image.open(frame_path).convert("RGBA")

        # Frame dimensions
        frame_width, frame_height = 1705, 1705
        hole_width, hole_height = 1400, 1400

        # Resize the frame to the expected dimensions if needed
        if frame.size != (frame_width, frame_height):
            frame = frame.resize((frame_width, frame_height))

        # Resize the base image to fit the hole
        base_image = base_image.resize((hole_width, hole_height))

        # Create a new blank image with frame dimensions
        result = Image.new("RGBA", (frame_width, frame_height), (0, 0, 0, 0))

        # Calculate the position to paste the base image (centered in the frame)
        x_offset = (frame_width - hole_width) // 2
        y_offset = (frame_height - hole_height) // 2

        # Paste the base image onto the blank canvas
        result.paste(base_image, (x_offset, y_offset))

        # Composite the frame over the base image
        result = Image.alpha_composite(result, frame)

        # Convert back to RGB
        final_image = result.convert("RGB")

        # Save the result to bytes
        result_bytes = io.BytesIO()
        final_image.save(result_bytes, format="PNG")
        result_bytes.seek(0)  # Reset the pointer to the beginning

        return result_bytes
