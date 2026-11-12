/* Nokcandu controller buttons carry no position. Real mouse buttons stay
 * absolute; the reserved negative encoding is produced only by our selector. */
static inline int nokcandu_controller_button(int encoded)
{
    return encoded <= -1 && encoded >= -5 ? -encoded - 1 : -1;
}
