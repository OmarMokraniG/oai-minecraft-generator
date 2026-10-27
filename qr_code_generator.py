import io

import qrcode


def generate_qr_code(url):
    """Generate a QR code for the given URL and return bytes."""
    # Generate the QR code
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(url)
    qr.make(fit=True)

    # Create an image from the QR code in memory
    img = qr.make_image(fill_color="black", back_color="white")

    # Save image to bytes buffer
    img_bytes = io.BytesIO()
    img.save(img_bytes, format="PNG")
    img_bytes.seek(0)

    return img_bytes
