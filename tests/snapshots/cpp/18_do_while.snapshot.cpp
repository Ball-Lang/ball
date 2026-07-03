
namespace {


} // namespace

int main() {
    auto i = BallDyn(static_cast<int64_t>(0));
    do {
        std::cout << ball_to_string(ball_to_string(i)) << std::endl;
        ball_assign(i, (i + static_cast<int64_t>(1)));
    } while ((i < static_cast<int64_t>(3)));
    auto j = BallDyn(static_cast<int64_t>(10));
    do {
        std::cout << ball_to_string(ball_to_string(j)) << std::endl;
        ball_assign(j, (j + static_cast<int64_t>(1)));
    } while ((j < static_cast<int64_t>(5)));
    std::cout << ball_to_string("done"s) << std::endl;
    return 0;
}
