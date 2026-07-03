
namespace {

BallDyn square(int64_t x);
BallDyn sumOfSquares(int64_t a, int64_t b);

BallDyn square(int64_t x) {
    auto& input = x;
    return (x * x);
    return BallDyn();
}

BallDyn sumOfSquares(int64_t a, int64_t b) {
    return (square(a) + square(b));
    return BallDyn();
}

} // namespace

int main() {
    std::cout << ball_to_string(ball_to_string(sumOfSquares(static_cast<int64_t>(3), static_cast<int64_t>(4)))) << std::endl;
    std::cout << ball_to_string(ball_to_string(sumOfSquares(static_cast<int64_t>(5), static_cast<int64_t>(12)))) << std::endl;
    return 0;
}
